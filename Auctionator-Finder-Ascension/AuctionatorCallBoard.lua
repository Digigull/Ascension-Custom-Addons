-------------------------------------------------------------------------------
-- AuctionatorCallBoard.lua
--
-- BACKLOG item 28, STAGE 0: RECONNAISSANCE, NOT A FEATURE.
--
-- WHAT THE QUESTION IS.  Every number the Analysis tab shows is an EFFECT --
-- Sold/day is demand after it happened, a price series is demand after it moved
-- the price.  The Hero's Call Board publishes what the server will WANT this
-- week, before a single listing changes hands, and it is the only leading
-- indicator this addon can reach.  Whether it can reach it is the whole risk,
-- and nothing offline can answer it: a bespoke Ascension frame is not required
-- to expose its contents to Lua.  This file asks the client, once, in the one
-- form that comes back as evidence -- a copy/paste window, never chat.
--
-- WHAT THE OWNER'S 2026-08-21 SCREENSHOTS ALREADY SETTLED, so this does not go
-- looking for it again:
--
--   * The board IS a custom frame.  Categories down the left (Weekly Rewards,
--     PvE, PvP, Professions, ...), quest cards with "Complete Now", "Accept All
--     Quests", a cache progress bar, reset timers.  Nothing in stock 3.3.5
--     draws that, so the gossip/quest-greeting APIs are the LEAST likely route
--     and are dumped here for completeness rather than in hope.
--
--   * The quests behind it are REAL QUEST LOG ENTRIES.  The chat log says
--     "A Thin Line: Raw Nightfin Snapper has been removed from your quest log",
--     which the client only says about a quest it held.  So the strong route is
--     the one the owner proposed: ACCEPT ALL, then read the log -- where
--     GetQuestLogLeaderBoard returns objective strings of the "Silk Bandage:
--     0/30" shape, which is the form item 28 actually wants, name and count in
--     one string, no frame scraping at all.
--
--   * The board's own tooltip states the requirement outright ("Requirements:
--     - Silk Bandage x 30").  That is the fallback if the log route is barred:
--     hover a card, read GameTooltip.  It is captured here because a tooltip
--     read has to happen WHILE hovering, which a slash command cannot do.
--
-- SO THE DUMP HAS FIVE INDEPENDENT SECTIONS and any one of them succeeding is
-- enough to build on.  Ranked by what they would buy:
--
--   1. QUEST LOG      -- accept all, then read.  Name and count, exactly.
--   2. FRAMES         -- can Lua see the board's text without accepting?
--   3. GLOBALS        -- did Ascension leave the board's DATA in a Lua table?
--   4. TOOLTIP        -- the requirement line, if the card itself is opaque.
--   5. QUEST GIVER    -- the stock APIs, for the record.
--
-- NOTHING IS ASSUMED ABOUT ANY SIGNATURE.  Every client call goes through
-- Atr_CB_Call, which reports ABSENT rather than erroring and prints ALL returns
-- by count -- because on a custom server "GetQuestLogTitle returns eight things"
-- is itself a finding, and a diagnostic that assumed the stock signature would
-- hide exactly the difference it was sent to look for.
--
-- THE EVENT TAPE RECORDS FROM LOAD, and that is a deliberate exception to the
-- house "ship it dark and off" habit.  Which events a custom board fires can
-- only be seen WHILE it is opened, so a tape that had to be armed first would
-- cost the owner a second trip to the board -- the round trip this whole file
-- exists to avoid.  It is a capped ring with consecutive repeats folded into a
-- count, so QUEST_LOG_UPDATE's ordinary chatter costs one table field.
-- /atrcallboard watch off stops it for the session.
--
-- WHAT HAPPENS TO THIS FILE.  If a route reads, stages 1-3 grow here and the
-- diagnostic stays as their debug command.  If none does, item 28 is dead in
-- this form and the file is deleted whole -- which is why it is a file and not
-- an edit spread across five.
--
-------------------------------------------------------------------------------
-- STAGE 0 CAME BACK, 2026-08-20.  ALL FOUR ROUTES READ.  The recon above stands
-- as written; what follows is the capture it authorised, and the readings that
-- decided its shape.  Full dump and reasoning: BACKLOG.md item 28.
--
--   * GOSSIP WORKS, which nobody expected of a bespoke frame.  The board is a
--     real gossip NPC wearing a custom UI: GetGossipAvailableQuests names the
--     quests you have NOT taken, GetGossipActiveQuests the ones you have.  That
--     is the whole board readable WITHOUT ACCEPTING ANYTHING, passively, on an
--     event -- the fourth-harvester shape this item asked for and did not
--     expect to get.  Titles and levels only: no counts.
--
--   * THE QUEST LOG CARRIES A QUEST ID.  GetQuestLogTitle returns NINE values
--     here, not the stock eight, and the ninth is the questID (1005094 for
--     "A Delicate Situation: Dense Stone").  A durable key that survives a
--     locale change, which a title string does not.  Slot 8, isDaily, is set on
--     exactly the board's daily quests.  Objectives read "Dense Stone: 3/40",
--     type "item" -- name, held and NEEDED, which is the count gossip lacks.
--
--   * THE BOARD IS A PLAIN LUA TABLE.  CallBoardUI, a 1024x702 DIALOG frame,
--     and its whole tree is reachable: 6313 globals matched the sweep, named
--     with dotted paths like
--     CallBoardUI.content.statisticsContent.Profession.VanillaGatheringADelicateSituation.
--     Not used by the capture below -- the two APIs above are cheaper and do not
--     depend on Ascension's frame names -- but it is the escape hatch if they
--     ever stop being enough, and /atrcallboard tree exists to survey it.
--
--   * THE TOOLTIP STATES THE REQUIREMENT.  Hovering a card gives "Requirements:
--     / - Dense Stone x 40".  This is the ONLY route to a count for a quest you
--     have not accepted, so it is harvested on hover.
--
-- SO THE CAPTURE IS A JOIN, and each feed covers the others' blind spot:
--
--   gossip  -> every quest on the board, taken or not       (no counts)
--   log     -> exact item and count, plus questID            (accepted only)
--   tooltip -> exact item and count                          (hovered only)
--
-- IT STORES AND DOES NOT READ, and that is the same one-way-door argument that
-- shipped item 31's history dark: a reader can be written next month, but a
-- WEEK THAT WAS NOT CAPTURED IS GONE.  The board rotates weekly, so every week
-- played without this is a week of rotation that no later work can recover.
-- Stage 2 (a "wanted this week" mark on Market and Reagents rows) and stage 3
-- (recurrence across weeks) are deliberately not here.
--
-- WHY IT DOES NOT GO IN THE COMPANION HISTORY FILE, which is the obvious home
-- until you look at the bargain: HISTORY-STORE.md admits that file to endanger
-- only itself, and the price is that EVERYTHING IN IT IS RE-DERIVABLE BY
-- SCANNING.  Last week's board is not re-derivable by anything.  It is small --
-- a dozen quests a week, kept for a season, is tens of kilobytes -- so it goes
-- in the main file where the un-re-derivable things already live.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function CBT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- Caps.  A diagnostic that fills the box with the action bars' font strings has
-- buried its own answer, and an EditBox the owner has to scroll for ten minutes
-- is not evidence anybody works from.
local ATR_CB_MAX_WINDOWS  = 8;      -- shown frames given a full text walk
local ATR_CB_MAX_TEXTS    = 60;     -- font strings reported per window
local ATR_CB_MAX_DEPTH    = 4;      -- child recursion inside a window
local ATR_CB_MAX_GLOBALS  = 40;     -- name-matched globals listed
local ATR_CB_MAX_FRAMES   = 20000;  -- EnumerateFrames walk backstop
local ATR_CB_TAPE_LEN     = 80;     -- event tape ring
local ATR_CB_MAX_LOG      = 80;     -- quest log entries walked

-- A window big enough to be the board.  The board fills most of the screen; the
-- point of the threshold is to skip the hundreds of small frames every UI has.
local ATR_CB_MIN_W = 300;
local ATR_CB_MIN_H = 200;

-- Substrings that would name a call board frame or the tooltip it draws.  Loose
-- on purpose: this list is only ever applied to VISIBLE frames, so a false hit
-- costs a few lines and a miss costs the feature.
local ATR_CB_HINTS = {
	"callboard", "call_board", "calling", "herocall", "heroscall",
	"questboard", "questbook", "bulletin", "board", "tooltip",
	"ascension", "asc_", "questframe",
};

-- Substrings for the GLOBALS sweep, which needs the opposite discipline: it
-- runs over all of _G, so "tooltip" alone would list sixty GameTooltip regions
-- and crowd out the one table worth finding.
local ATR_CB_DATA_HINTS = {
	"callboard", "call_board", "calling", "herocall", "heroscall",
	"questboard", "questbook", "bulletin", "ascension", "asc_",
};

local ATR_CB_EVENTS = {
	"GOSSIP_SHOW", "GOSSIP_CLOSED",
	"QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE",
	"QUEST_FINISHED", "QUEST_ACCEPTED", "QUEST_LOG_UPDATE",
	"QUEST_ITEM_UPDATE", "UNIT_QUEST_LOG_CHANGED",
};

local gCBTape     = {};     -- ring of { ev, arg, t, n }
local gCBTapeOn   = true;
local gCBFrame    = nil;
local gCBLastTip  = nil;    -- { owner, lines }

-------------------------------------------------------------------------------
-- formatting
-------------------------------------------------------------------------------

local function Atr_CB_Str (v, cap)

	if (v == nil) then return "nil"; end

	local t = type (v);

	if (t == "string") then
		local s = v:gsub ("[\r\n]", "\\n");
		if (cap and cap > 0 and #s > cap) then s = s:sub (1, cap) .. "..."; end
		return "\"" .. s .. "\"";
	end

	if (t == "number" or t == "boolean") then return tostring (v); end
	if (t == "table")    then return "<table>";    end
	if (t == "function") then return "<function>"; end

	return "<" .. t .. ">";
end

-- Keeps the RETURN COUNT, which { pcall(...) } alone loses to trailing nils --
-- and "returned nil in slot 4" versus "returned only 3 things" is exactly the
-- kind of difference this dump is being sent to find.
local function Atr_CB_Pack (...)
	return select ("#", ...), { ... };
end

-- Reports a client call without assuming it exists or what it returns.
local function Atr_CB_Call (out, indent, fname, ...)

	local fn = rawget (_G, fname);

	if (type (fn) ~= "function") then
		out[#out + 1] = indent .. fname .. "  --  ABSENT";
		return nil;
	end

	local n, r = Atr_CB_Pack (pcall (fn, ...));

	if (not r[1]) then
		out[#out + 1] = indent .. fname .. "  --  ERROR: " .. tostring (r[2]);
		return nil;
	end

	if (n < 2) then
		out[#out + 1] = indent .. fname .. "  ->  (no returns)";
		return nil;
	end

	local parts = {};
	for i = 2, n do parts[#parts + 1] = Atr_CB_Str (r[i], 90); end

	out[#out + 1] = indent .. fname .. "  ->  " .. table.concat (parts, ", ");

	return r[2];
end

-------------------------------------------------------------------------------
-- 1. the quest log -- the route the owner proposed, and the strongest one
-------------------------------------------------------------------------------

-- Collapsed headers hide their quests from the walk entirely, so a dump taken
-- with the Professions header collapsed would report NOTHING and read exactly
-- like "the log route does not work".  Expand, walk, put it back.
local function Atr_CB_Expand ()

	local getNum   = rawget (_G, "GetNumQuestLogEntries");
	local getTitle = rawget (_G, "GetQuestLogTitle");
	local expand   = rawget (_G, "ExpandQuestHeader");

	if (type (getNum) ~= "function" or type (getTitle) ~= "function") then return nil; end

	local wasCollapsed = {};
	local n = getNum ();

	for i = 1, math.min (n or 0, ATR_CB_MAX_LOG) do
		local title, _, _, _, isHeader, isCollapsed = getTitle (i);
		if (isHeader and isCollapsed) then wasCollapsed[tostring (title or i)] = true; end
	end

	if (next (wasCollapsed) == nil) then return nil; end
	if (type (expand) == "function") then pcall (expand, 0); end

	return wasCollapsed;
end

local function Atr_CB_Recollapse (wasCollapsed)

	if (wasCollapsed == nil) then return; end

	local getNum    = rawget (_G, "GetNumQuestLogEntries");
	local getTitle  = rawget (_G, "GetQuestLogTitle");
	local collapse  = rawget (_G, "CollapseQuestHeader");

	if (type (getNum) ~= "function" or type (getTitle) ~= "function") then return; end
	if (type (collapse) ~= "function") then return; end

	-- Descending, because collapsing a header renumbers everything below it.
	local n = math.min (getNum () or 0, ATR_CB_MAX_LOG);
	for i = n, 1, -1 do
		local title, _, _, _, isHeader = getTitle (i);
		if (isHeader and wasCollapsed[tostring (title or i)]) then pcall (collapse, i); end
	end
end

local function Atr_CB_QuestLog (out)

	out[#out + 1] = "== 1. QUEST LOG ==";

	local getNum   = rawget (_G, "GetNumQuestLogEntries");
	local getTitle = rawget (_G, "GetQuestLogTitle");

	if (type (getNum) ~= "function" or type (getTitle) ~= "function") then
		out[#out + 1] = "  GetNumQuestLogEntries / GetQuestLogTitle ABSENT -- no log route.";
		out[#out + 1] = "";
		return;
	end

	local select_    = rawget (_G, "SelectQuestLogEntry");
	local getSel     = rawget (_G, "GetQuestLogSelection");
	local getNumLb   = rawget (_G, "GetNumQuestLeaderBoards");
	local getLb      = rawget (_G, "GetQuestLogLeaderBoard");
	local getText    = rawget (_G, "GetQuestLogQuestText");

	local restoreSel   = (type (getSel) == "function") and getSel () or nil;
	local wasCollapsed = Atr_CB_Expand ();

	local numEntries, numQuests = getNum ();
	out[#out + 1] = string.format ("  GetNumQuestLogEntries -> %s entries, %s quests",
	                               tostring (numEntries), tostring (numQuests));
	out[#out + 1] = "  (all returns of GetQuestLogTitle, in order, then each objective)";

	for i = 1, math.min (numEntries or 0, ATR_CB_MAX_LOG) do

		local n, r = Atr_CB_Pack (pcall (getTitle, i));
		local parts = {};
		for k = 2, n do parts[#parts + 1] = Atr_CB_Str (r[k], 60); end

		out[#out + 1] = string.format ("  [%2d] %s%s", i, r[1] and "" or "ERROR ",
		                               table.concat (parts, ", "));

		-- r[1] is pcall's own ok, so the stock returns start one along and
		-- isHeader -- fifth of GetQuestLogTitle -- lands in slot six.
		local isHeader = r[6];

		if (not isHeader) then

			if (type (select_) == "function") then pcall (select_, i); end

			local nOb = 0;
			if (type (getNumLb) == "function") then
				local ok, v = pcall (getNumLb, i);
				if (ok and type (v) == "number") then nOb = v; end
			end

			if (type (getText) == "function") then
				local ok, desc, obj = pcall (getText);
				if (ok and obj and obj ~= "") then
					out[#out + 1] = "         objective text: " .. Atr_CB_Str (obj, 160);
				end
			end

			if (nOb > 0 and type (getLb) == "function") then
				for j = 1, nOb do
					local m, lr = Atr_CB_Pack (pcall (getLb, j, i));
					if (lr[1]) then
						local lp = {};
						for k = 2, m do lp[#lp + 1] = Atr_CB_Str (lr[k], 90); end
						out[#out + 1] = string.format ("         obj %d: %s", j, table.concat (lp, ", "));
					else
						out[#out + 1] = string.format ("         obj %d: ERROR %s", j, tostring (lr[2]));
					end
				end
			elseif (nOb == 0) then
				out[#out + 1] = "         (no leader boards)";
			end
		end
	end

	if (type (select_) == "function" and restoreSel) then pcall (select_, restoreSel); end
	Atr_CB_Recollapse (wasCollapsed);

	if (wasCollapsed) then
		out[#out + 1] = "  (collapsed headers were expanded for this walk and put back)";
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- 2. the frames -- can Lua read the board without accepting anything
-------------------------------------------------------------------------------

local function Atr_CB_Hinted (name, hints)

	if (type (name) ~= "string") then return false; end

	hints = hints or ATR_CB_HINTS;

	local lower = name:lower ();
	for i = 1, #hints do
		if (lower:find (hints[i], 1, true)) then return true; end
	end

	return false;
end

local function Atr_CB_WalkText (f, out, indent, depth, budget)

	if (depth > ATR_CB_MAX_DEPTH or budget.n >= ATR_CB_MAX_TEXTS) then return; end

	local ok, regions = pcall (function () return { f:GetRegions () }; end);
	if (ok) then
		for i = 1, #regions do
			local r = regions[i];
			if (budget.n >= ATR_CB_MAX_TEXTS) then break; end
			if (r and r.GetObjectType and r:GetObjectType () == "FontString" and r.GetText) then
				local s = r:GetText ();
				if (s and s ~= "") then
					budget.n = budget.n + 1;
					out[#out + 1] = indent .. Atr_CB_Str (s, 110);
				end
			end
		end
	end

	local okc, kids = pcall (function () return { f:GetChildren () }; end);
	if (not okc) then return; end

	for i = 1, #kids do
		local c = kids[i];
		if (budget.n >= ATR_CB_MAX_TEXTS) then break; end
		if (c) then
			-- Buttons carry their label on themselves, not in a region.
			if (c.GetText) then
				local okt, s = pcall (function () return c:GetText (); end);
				if (okt and s and s ~= "") then
					budget.n = budget.n + 1;
					out[#out + 1] = indent .. "[btn] " .. Atr_CB_Str (s, 110);
				end
			end
			Atr_CB_WalkText (c, out, indent, depth + 1, budget);
		end
	end
end

local function Atr_CB_Frames (out)

	out[#out + 1] = "== 2. SHOWN FRAMES ==";

	local enum = rawget (_G, "EnumerateFrames");
	if (type (enum) ~= "function") then
		out[#out + 1] = "  EnumerateFrames ABSENT -- cannot sweep frames.";
		out[#out + 1] = "";
		return;
	end

	local hits, seen, guard = {}, 0, 0;
	local f = enum ();

	while (f and guard < ATR_CB_MAX_FRAMES) do

		guard = guard + 1;

		local okv, visible = pcall (function () return f:IsVisible (); end);
		if (okv and visible) then

			local name = (f.GetName and f:GetName ()) or nil;
			local w    = (f.GetWidth  and f:GetWidth  ()) or 0;
			local h    = (f.GetHeight and f:GetHeight ()) or 0;

			-- Skip our own windows: on a second run the debug box is itself a
			-- big shown frame, and it would eat a slot to report its own text.
			local mine = (type (name) == "string") and (name:find ("Atr", 1, true) == 1);

			if (not mine and ((w >= ATR_CB_MIN_W and h >= ATR_CB_MIN_H) or Atr_CB_Hinted (name))) then
				seen = seen + 1;
				if (#hits < ATR_CB_MAX_WINDOWS) then hits[#hits + 1] = f; end
			end
		end

		f = enum (f);
	end

	out[#out + 1] = string.format ("  %d visible frame(s) matched (large, or name-hinted); showing %d",
	                               seen, #hits);

	for i = 1, #hits do

		local fr   = hits[i];
		local name = (fr.GetName and fr:GetName ()) or "<anonymous>";
		local typ  = (fr.GetObjectType and fr:GetObjectType ()) or "?";
		local str  = (fr.GetFrameStrata and fr:GetFrameStrata ()) or "?";
		local w    = (fr.GetWidth  and fr:GetWidth  ()) or 0;
		local h    = (fr.GetHeight and fr:GetHeight ()) or 0;

		out[#out + 1] = string.format ("  --- %s  [%s, %s, %dx%d]", tostring (name), typ, str,
		                               math.floor (w + 0.5), math.floor (h + 0.5));

		local budget = { n = 0 };
		Atr_CB_WalkText (fr, out, "        ", 1, budget);

		if (budget.n == 0) then
			out[#out + 1] = "        (no readable text)";
		elseif (budget.n >= ATR_CB_MAX_TEXTS) then
			out[#out + 1] = string.format ("        (capped at %d strings)", ATR_CB_MAX_TEXTS);
		end
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- 3. the globals -- the jackpot case: the board's data left in a Lua table
-------------------------------------------------------------------------------

local function Atr_CB_Globals (out)

	out[#out + 1] = "== 3. NAME-MATCHED GLOBALS ==";

	-- TABLES ONLY.  A function called something-Board is a name, not data; the
	-- find worth having is a TABLE holding the board's quests, and restricting to
	-- tables is what keeps the cap free for it.
	local shown, total = 0, 0;

	for k, v in pairs (_G) do
		if (type (k) == "string" and type (v) == "table" and Atr_CB_Hinted (k, ATR_CB_DATA_HINTS)) then

			total = total + 1;

			if (shown < ATR_CB_MAX_GLOBALS) then

				shown = shown + 1;

				-- Bounded: a table with ten thousand keys is not worth counting
				-- exactly, and counting it is how a diagnostic hangs the client.
				local cnt, capped, keys = 0, false, {};
				for kk in pairs (v) do
					cnt = cnt + 1;
					if (#keys < 6) then keys[#keys + 1] = tostring (kk); end
					if (cnt >= 500) then capped = true; break; end
				end

				local isFrame = (type (v.GetObjectType) == "function");

				out[#out + 1] = string.format ("  %s = table, %d%s key(s)%s  { %s }",
				                               k, cnt, capped and "+" or "",
				                               isFrame and " [frame]" or "",
				                               table.concat (keys, ", "));
			end
		end
	end

	out[#out + 1] = string.format ("  (%d matched, %d shown)", total, shown);
	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- 4. the tooltip -- the requirement line, captured while it was up
-------------------------------------------------------------------------------

local function Atr_CB_SnapTooltip ()

	local tip = rawget (_G, "GameTooltip");
	if (tip == nil or type (tip.NumLines) ~= "function") then return; end

	local ok, n = pcall (function () return tip:NumLines (); end);
	if (not ok or (n or 0) < 1) then return; end

	local lines = {};
	for i = 1, n do
		local l = rawget (_G, "GameTooltipTextLeft" .. i);
		local r = rawget (_G, "GameTooltipTextRight" .. i);
		local ls = (l and l.GetText and l:GetText ()) or "";
		local rs = (r and r.GetText and r:GetText ()) or "";
		if (ls ~= "" or rs ~= "") then
			lines[#lines + 1] = (rs ~= "") and (ls .. "  |  " .. rs) or ls;
		end
	end

	if (#lines == 0) then return; end

	local owner = nil;
	local oko, o = pcall (function () return tip:GetOwner (); end);
	if (oko and o and o.GetName) then owner = o:GetName (); end

	gCBLastTip = { owner = owner, lines = lines };

	-- STAGE 1: a hovered card is the only route to the count of a quest the
	-- player has not accepted, so the snapshot files it as well as showing it.
	if (type (Atr_CB_NoteTooltip) == "function") then pcall (Atr_CB_NoteTooltip, gCBLastTip); end
end

local function Atr_CB_Tooltip (out)

	out[#out + 1] = "== 4. LAST TOOLTIP ==";

	if (gCBLastTip == nil) then
		out[#out + 1] = "  none captured -- hover a quest card on the board, then dump.";
		out[#out + 1] = "  (nothing captured after hovering a card means the board draws its own";
		out[#out + 1] = "   tooltip rather than using GameTooltip -- which is itself the answer)";
	else
		out[#out + 1] = "  owner: " .. tostring (gCBLastTip.owner or "<anonymous>");
		for i = 1, #gCBLastTip.lines do
			out[#out + 1] = "    " .. Atr_CB_Str (gCBLastTip.lines[i], 140);
		end
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- 5. the stock quest-giver APIs -- for the record
-------------------------------------------------------------------------------

local function Atr_CB_QuestGiver (out)

	out[#out + 1] = "== 5. QUEST GIVER APIs ==";

	local n;

	Atr_CB_Call (out, "  ", "GetNumGossipAvailableQuests");
	Atr_CB_Call (out, "  ", "GetGossipAvailableQuests");
	Atr_CB_Call (out, "  ", "GetNumGossipActiveQuests");
	Atr_CB_Call (out, "  ", "GetGossipActiveQuests");

	n = Atr_CB_Call (out, "  ", "GetNumAvailableQuests");
	if (type (n) == "number") then
		for i = 1, math.min (n, 25) do Atr_CB_Call (out, "    ", "GetAvailableTitle", i); end
	end

	n = Atr_CB_Call (out, "  ", "GetNumActiveQuests");
	if (type (n) == "number") then
		for i = 1, math.min (n, 25) do Atr_CB_Call (out, "    ", "GetActiveTitle", i); end
	end

	Atr_CB_Call (out, "  ", "GetTitleText");
	Atr_CB_Call (out, "  ", "GetObjectiveText");
	Atr_CB_Call (out, "  ", "GetQuestID");

	n = Atr_CB_Call (out, "  ", "GetNumQuestItems");
	if (type (n) == "number") then
		for i = 1, math.min (n, 25) do Atr_CB_Call (out, "    ", "GetQuestItemInfo", "required", i); end
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- 6. the event tape
-------------------------------------------------------------------------------

local function Atr_CB_Tape (out)

	out[#out + 1] = "== 6. EVENT TAPE ==";
	out[#out + 1] = "  recording: " .. (gCBTapeOn and "on" or "off");

	if (#gCBTape == 0) then
		out[#out + 1] = "  nothing fired -- if the board was opened and closed with this empty,";
		out[#out + 1] = "  it talks to the server without any client quest event, and stages 1-3";
		out[#out + 1] = "  cannot hook the opening at all.";
	else
		for i = 1, #gCBTape do
			local e = gCBTape[i];
			out[#out + 1] = string.format ("  %s  %s%s%s", tostring (e.t), tostring (e.ev),
			                               (e.arg ~= nil) and ("  " .. Atr_CB_Str (e.arg, 40)) or "",
			                               (e.n > 1) and string.format ("  x%d", e.n) or "");
		end
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- the tree probe -- surveying CallBoardUI, if the two APIs ever stop being enough
--
-- Not used by the capture, and deliberately: the gossip and quest log routes do
-- not depend on any Ascension frame name, and a capture built on this tree would
-- break the first time the board is restyled.  It exists because the sweep found
-- 6313 globals under CallBoardUI, and if a later stage needs something the APIs
-- do not carry -- the group's remaining-completion budget, the exact reset time,
-- the per-category quest lists for categories the player has not opened -- this
-- is where it will be.
-------------------------------------------------------------------------------

local function Atr_CB_TreeInto (t, out, indent, depth)

	if (depth > 2) then return; end

	local plain, frames, fns = {}, {}, 0;

	for k, v in pairs (t) do
		local tv = type (v);
		if (tv == "function") then
			fns = fns + 1;
		elseif (tv == "table") then
			frames[#frames + 1] = k;
		else
			plain[#plain + 1] = string.format ("%s = %s", tostring (k), Atr_CB_Str (v, 70));
		end
	end

	table.sort (plain);
	table.sort (frames, function (a, b) return tostring (a) < tostring (b); end);

	for i = 1, math.min (#plain, 24) do out[#out + 1] = indent .. plain[i]; end
	if (#plain > 24) then out[#out + 1] = indent .. string.format ("... %d more values", #plain - 24); end
	if (fns > 0)     then out[#out + 1] = indent .. string.format ("(%d method(s))", fns); end

	for i = 1, math.min (#frames, 24) do
		local k = frames[i];
		out[#out + 1] = indent .. tostring (k) .. ":";
		Atr_CB_TreeInto (t[k], out, indent .. "    ", depth + 1);
	end
	if (#frames > 24) then out[#out + 1] = indent .. string.format ("... %d more tables", #frames - 24); end
end

local function Atr_CB_Tree (out)

	out[#out + 1] = "== CallBoardUI TREE ==";

	local root = rawget (_G, "CallBoardUI");
	if (type (root) ~= "table") then
		out[#out + 1] = "  CallBoardUI absent -- open a Hero's Call Board first.";
		out[#out + 1] = "";
		return;
	end

	Atr_CB_TreeInto (root, out, "  ", 1);
	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- STAGE 1: the capture
--
-- Passive, in the shape of the other three harvesters (profession window,
-- merchant window, mail sweep): it captures from a window the player opened
-- anyway, stores what it saw, and never asks them to do anything.
-------------------------------------------------------------------------------

-- A season of weeks.  The point of keeping several is the ROTATION -- "this
-- material came up in 3 of the last 8 weeks" is a better farming signal than any
-- single week -- and at roughly a kilobyte a week that is cheap enough not to
-- need an argument.
local ATR_CB_WEEKS = 26;

-- 2008-08-01, the same epoch AuctionatorHistory.lua packs its day numbers
-- against.  Shared so the two stores' bucket numbers are comparable if a reader
-- ever wants to line a price series up against the week a material was wanted.
local ATR_CB_DAY0 = 1217548800;

-- THE BUCKET IS NOT THE SERVER'S WEEK, and pretending otherwise is the one
-- mistake this could bake in.  The board shows "Weekly Quest Reset 5 Days 11
-- Hours", so the reset is knowable, but only as text in a frame -- and a capture
-- keyed off a countdown string would break the day Ascension rewords it.  A
-- fixed seven-day bucket is stable, and it is enough for the question actually
-- asked: two adjacent buckets are still "then" and "now", and recurrence over a
-- season does not care that the boundary sits a few days off the reset.  Any
-- reader that wants to NAME the reset day must take it from a setting, per this
-- item's own honest limits.
function Atr_CB_Week (t)
	t = t or (time and time ()) or 0;
	return math.floor ((t - ATR_CB_DAY0) / (7 * 24 * 60 * 60));
end

function Atr_CB_DB ()

	if (type (AUCTIONATOR_CALLBOARD) ~= "table") then AUCTIONATOR_CALLBOARD = {}; end

	local db = AUCTIONATOR_CALLBOARD;
	if (db.ver == nil) then db.ver = 1; end
	if (type (db.weeks) ~= "table") then db.weeks = {}; end

	return db;
end

-- Trimming runs on write, not at login: walking the store at load is the cost
-- item 31 went out of its way not to add, and this table is small enough that
-- the walk is a couple of dozen keys.
local function Atr_CB_Trim (db)

	local newest = nil;
	for wk in pairs (db.weeks) do
		if (newest == nil or wk > newest) then newest = wk; end
	end

	if (newest == nil) then return; end

	for wk in pairs (db.weeks) do
		if (wk < newest - ATR_CB_WEEKS) then db.weeks[wk] = nil; end
	end
end

-- One quest, merged into this week's record.  Every feed lands here, and the
-- merge is deliberately additive: gossip knows the title, the log knows the
-- count, the tooltip knows the count for quests gossip saw but the log cannot.
-- Whichever arrives second must not erase what the first one knew.
function Atr_CB_Note (title, fields)

	if (type (title) ~= "string" or title == "") then return nil; end

	local db  = Atr_CB_DB ();
	local now = (time and time ()) or 0;
	local wk  = Atr_CB_Week (now);

	if (type (db.weeks[wk]) ~= "table") then
		db.weeks[wk] = { first = now, q = {} };
		Atr_CB_Trim (db);
	end

	local week = db.weeks[wk];
	if (type (week.q) ~= "table") then week.q = {}; end

	local rec = week.q[title];
	if (rec == nil) then
		rec = { seen = now, it = {} };
		week.q[title] = rec;
	end

	rec.last = now;

	if (fields) then
		if (fields.id   and rec.id   == nil) then rec.id   = fields.id;   end
		if (fields.cat  and rec.cat  == nil) then rec.cat  = fields.cat;  end
		if (fields.kind and rec.kind == nil) then rec.kind = fields.kind; end
		if (fields.item and fields.item ~= "") then
			-- A count already stored is not overwritten with a smaller one: the
			-- log reports what is STILL needed as progress is made, and the
			-- demand this item measures is what the quest asked for, not what is
			-- left of it.
			local have = rec.it[fields.item];
			local want = tonumber (fields.need) or 0;
			if (have == nil or want > have) then rec.it[fields.item] = want; end
		end
	end

	return rec;
end

-- Is the board actually up.  Without this gate every ordinary NPC's gossip
-- would be filed as a call board quest, which would poison the store silently --
-- the worst failure available here, since nothing reads it yet to look wrong.
function Atr_CB_BoardUp ()

	local f = rawget (_G, "CallBoardUI");
	if (type (f) ~= "table" or type (f.IsVisible) ~= "function") then return false; end

	local ok, vis = pcall (function () return f:IsVisible (); end);
	return (ok and vis) and true or false;
end

-- The gossip lists come back FLAT -- one run of values per quest -- and the
-- stride differs between the two calls (5 available, 4 active on this client).
-- It is derived from the returns rather than written down, for the same reason
-- nothing else here hardcodes a signature.
local function Atr_CB_Gossip (fname, countName)

	local fn  = rawget (_G, fname);
	local cfn = rawget (_G, countName);

	if (type (fn) ~= "function" or type (cfn) ~= "function") then return {}; end

	local okc, count = pcall (cfn);
	if (not okc or type (count) ~= "number" or count < 1) then return {}; end

	local n, r = Atr_CB_Pack (pcall (fn));
	if (not r[1] or n < 2) then return {}; end

	local total  = n - 1;
	local stride = math.floor (total / count);
	if (stride < 1) then return {}; end

	local list = {};
	for i = 1, count do
		local base  = 1 + (i - 1) * stride;
		local title = r[base + 1];
		if (type (title) == "string" and title ~= "") then
			-- Slot 4 of the available list is isDaily on this client.  Absent or
			-- shifted, kind simply stays unknown; nothing downstream requires it.
			list[#list + 1] = { title = title, daily = (stride >= 4) and r[base + 4] or nil };
		end
	end

	return list;
end

-- The log supplies what gossip cannot: the item and how many.  Keyed by TITLE
-- because that is the only field the two sources share -- the questID is the
-- better key, and it is recorded, but gossip never states it.
local function Atr_CB_LogByTitle ()

	local getNum   = rawget (_G, "GetNumQuestLogEntries");
	local getTitle = rawget (_G, "GetQuestLogTitle");
	local getNumLb = rawget (_G, "GetNumQuestLeaderBoards");
	local getLb    = rawget (_G, "GetQuestLogLeaderBoard");

	if (type (getNum) ~= "function" or type (getTitle) ~= "function") then return {}; end

	local byTitle, header = {}, nil;
	local numEntries = getNum () or 0;

	for i = 1, math.min (numEntries, ATR_CB_MAX_LOG) do

		local n, r = Atr_CB_Pack (pcall (getTitle, i));

		if (r[1]) then

			local title    = r[2];
			local isHeader = r[6];
			local isDaily  = r[9];
			local questID  = r[10];   -- Ascension's ninth return; nil on a stock client

			if (isHeader) then
				header = title;
			elseif (type (title) == "string" and title ~= "") then

				local items = {};

				if (type (getNumLb) == "function" and type (getLb) == "function") then
					local okn, nOb = pcall (getNumLb, i);
					if (okn and type (nOb) == "number") then
						for j = 1, nOb do
							local m, lr = Atr_CB_Pack (pcall (getLb, j, i));
							-- "Dense Stone: 3/40", type "item".  Kill types are
							-- not demand for anything buyable, so they are dropped
							-- here rather than filtered by a later reader.
							if (lr[1] and lr[3] == "item" and type (lr[2]) == "string") then
								local name, _, need = lr[2]:match ("^(.-):%s*(%d+)%s*/%s*(%d+)%s*$");
								if (name and need) then
									items[#items + 1] = { item = name, need = tonumber (need) };
								end
							end
						end
					end
				end

				byTitle[title] = { id = questID, cat = header, daily = isDaily, items = items };
			end
		end
	end

	return byTitle;
end

-- The harvest itself.  Runs a frame after GOSSIP_SHOW, because the event beats
-- the board's own frame to the screen and the visibility gate would fail on a
-- board that was in fact open.
function Atr_CB_Harvest ()

	if (not Atr_CB_BoardUp ()) then return false; end

	local avail  = Atr_CB_Gossip ("GetGossipAvailableQuests", "GetNumGossipAvailableQuests");
	local active = Atr_CB_Gossip ("GetGossipActiveQuests",    "GetNumGossipActiveQuests");

	if (#avail == 0 and #active == 0) then return false; end

	local log, noted = Atr_CB_LogByTitle (), 0;

	local function file (entry, kindHint)

		local rec = Atr_CB_Note (entry.title, {
			kind = kindHint,
		});

		if (rec == nil) then return; end
		noted = noted + 1;

		local l = log[entry.title];
		if (l == nil) then return; end

		Atr_CB_Note (entry.title, {
			id   = l.id,
			cat  = l.cat,
			kind = l.daily and "d" or nil,
		});

		for i = 1, #l.items do
			Atr_CB_Note (entry.title, { item = l.items[i].item, need = l.items[i].need });
		end
	end

	for i = 1, #avail  do file (avail[i],  avail[i].daily and "d" or nil); end
	for i = 1, #active do file (active[i], nil); end

	return noted > 0;
end

-- The tooltip feed.  A quest you have not accepted has no log entry, so its
-- COUNT exists in exactly one place the client will show you: the card's own
-- tooltip.  Hovering is something the player does anyway, which keeps this
-- passive rather than a chore.
--
--   line 1            the quest title
--   "Requirements:"   then one " - <item> x <n>" per line until the block ends
--
function Atr_CB_NoteTooltip (tip)

	if (tip == nil or type (tip.lines) ~= "table" or #tip.lines < 2) then return false; end

	-- Only a call board card.  The owner name is Ascension's dotted frame path,
	-- so a substring test is the whole check.
	local owner = tip.owner;
	if (type (owner) ~= "string" or owner:lower ():find ("callboard", 1, true) == nil) then
		return false;
	end

	local title = tip.lines[1];
	if (type (title) ~= "string" or title == "") then return false; end

	local inReq, noted = false, 0;

	for i = 2, #tip.lines do

		local line = tostring (tip.lines[i] or "");

		if (line:find ("^%s*Requirements") ~= nil) then
			inReq = true;
		elseif (inReq) then
			local item, need = line:match ("^%s*%-%s*(.-)%s+x%s*(%d+)%s*$");
			if (item and need) then
				Atr_CB_Note (title, { item = item, need = tonumber (need) });
				noted = noted + 1;
			elseif (line:find ("^%s*$") == nil and line:find ("^%s*%-") == nil) then
				-- A non-blank line that is not a requirement ends the block --
				-- "Rewards" on this client, but not assumed to be that word.
				inReq = false;
			end
		end
	end

	if (noted > 0) then Atr_CB_Note (title, {}); end

	return noted > 0;
end

-------------------------------------------------------------------------------
-- the readout -- what has been captured, and nothing inferred from it
-------------------------------------------------------------------------------

function Atr_CB_Weeks (out)

	out[#out + 1] = "== CAPTURED WEEKS ==";

	local db = Atr_CB_DB ();

	local keys = {};
	for wk in pairs (db.weeks) do keys[#keys + 1] = wk; end
	table.sort (keys, function (a, b) return a > b; end);

	if (#keys == 0) then
		out[#out + 1] = "  nothing captured yet -- open a Hero's Call Board.";
		out[#out + 1] = "";
		return;
	end

	local thisWeek = Atr_CB_Week ();

	for k = 1, #keys do

		local wk   = keys[k];
		local week = db.weeks[wk];
		local when = (type (date) == "function" and week.first) and date ("%Y-%m-%d", week.first) or "?";

		local titles = {};
		for title in pairs (week.q or {}) do titles[#titles + 1] = title; end
		table.sort (titles);

		out[#out + 1] = string.format ("  week %d%s -- first seen %s, %d quest(s)",
		                               wk, (wk == thisWeek) and " (this week)" or "",
		                               when, #titles);

		for i = 1, #titles do

			local rec   = week.q[titles[i]];
			local items = {};
			for item, need in pairs (rec.it or {}) do
				items[#items + 1] = string.format ("%s x%d", item, need or 0);
			end
			table.sort (items);

			out[#out + 1] = string.format ("    [%s%s] %s", rec.kind or "?",
			                               rec.id and ("/" .. tostring (rec.id)) or "",
			                               titles[i]);

			if (#items > 0) then
				out[#out + 1] = "         " .. table.concat (items, ", ");
			else
				out[#out + 1] = "         (no count yet -- accept it, or hover its card)";
			end
		end
	end

	out[#out + 1] = "";
end

-------------------------------------------------------------------------------
-- the dump
-------------------------------------------------------------------------------

function Atr_CB_Dump (which)

	local out = {};

	out[#out + 1] = "Auctionator -- Call Board reconnaissance (BACKLOG item 28, stage 0)";
	out[#out + 1] = "Paste this back whole.  Sections 1-5 are independent; any one that";
	out[#out + 1] = "reads is enough to build on.";

	local when = (type (date) == "function") and date ("%Y-%m-%d %H:%M:%S") or "?";
	out[#out + 1] = "taken: " .. when;
	out[#out + 1] = "";

	which = (which and which ~= "") and which or "all";

	if (which == "all" or which == "log")    then Atr_CB_QuestLog   (out); end
	if (which == "all" or which == "frames") then Atr_CB_Frames     (out); end
	if (which == "all" or which == "frames") then Atr_CB_Globals    (out); end
	if (which == "all" or which == "tip")    then Atr_CB_Tooltip    (out); end
	if (which == "all" or which == "npc")    then Atr_CB_QuestGiver (out); end
	if (which == "all" or which == "tape")   then Atr_CB_Tape       (out); end
	if (which == "all" or which == "weeks")  then Atr_CB_Weeks      (out); end
	if (which == "tree")                     then Atr_CB_Tree       (out); end

	local text = table.concat (out, "\n");

	if (type (Atr_An_ShowDebugBox) == "function") then
		Atr_An_ShowDebugBox (CBT ("Call Board recon -- Ctrl+C to copy"), text);
		return true;
	end

	-- No box means no evidence: chat text cannot be selected on this client, so
	-- printing this would be forty lines nobody can send back.
	if (zc and zc.msg_atr) then
		zc.msg_atr (CBT ("Call Board: the copy/paste window is unavailable, so the dump was not shown"));
	end

	return false;
end

-------------------------------------------------------------------------------
-- wiring
-------------------------------------------------------------------------------

if (type (CreateFrame) == "function") then

	gCBFrame = CreateFrame ("Frame", "Atr_CallBoardRecon", UIParent);

	for i = 1, #ATR_CB_EVENTS do
		pcall (function () gCBFrame:RegisterEvent (ATR_CB_EVENTS[i]); end);
	end

	gCBFrame:SetScript ("OnEvent", function (self, event, arg1)

		if (not gCBTapeOn) then return; end

		local last = gCBTape[#gCBTape];
		if (last and last.ev == event and last.arg == arg1) then
			last.n = last.n + 1;
			return;
		end

		local when = (type (date) == "function") and date ("%H:%M:%S") or "?";
		gCBTape[#gCBTape + 1] = { ev = event, arg = arg1, t = when, n = 1 };

		while (#gCBTape > ATR_CB_TAPE_LEN) do table.remove (gCBTape, 1); end
	end);

	-- STAGE 1 runs a frame LATE, on purpose.  GOSSIP_SHOW beats the board's own
	-- frame to the screen, so a harvest that ran on the event itself would find
	-- CallBoardUI not yet visible and file nothing -- while looking, from
	-- outside, exactly like "the gossip route does not work".
	local harvest = CreateFrame ("Frame", nil, UIParent);
	harvest:Hide ();
	harvest:SetScript ("OnUpdate", function (self)
		self:Hide ();
		if (type (Atr_CB_Harvest) == "function") then pcall (Atr_CB_Harvest); end
	end);

	local hf = CreateFrame ("Frame", "Atr_CallBoardHarvest", UIParent);
	hf:RegisterEvent ("GOSSIP_SHOW");
	hf:RegisterEvent ("QUEST_ACCEPTED");
	hf:RegisterEvent ("QUEST_TURNED_IN");
	hf:SetScript ("OnEvent", function (self, event)
		-- Accepting a quest is what turns a gossip title into a countable log
		-- entry, so the board being open is the whole trigger condition and the
		-- gate inside Atr_CB_Harvest is what keeps ordinary NPCs out.
		harvest:Show ();
	end);

	-- The tooltip's text is not final at OnShow -- SetOwner fires the show and
	-- the lines are added after it -- so the snapshot is taken one frame later
	-- and the OnUpdate takes itself off again immediately.
	local tip = rawget (_G, "GameTooltip");
	if (tip and type (tip.HookScript) == "function") then
		local snap = CreateFrame ("Frame", nil, UIParent);
		snap:Hide ();
		snap:SetScript ("OnUpdate", function (self)
			self:Hide ();
			Atr_CB_SnapTooltip ();
		end);
		pcall (function ()
			tip:HookScript ("OnShow", function () snap:Show (); end);
		end);
	end
end

if (SlashCmdList) then

	SLASH_ATRCALLBOARD1 = "/atrcallboard";
	SLASH_ATRCALLBOARD2 = "/atrcb";

	SlashCmdList["ATRCALLBOARD"] = function (msg)

		local first = tostring (msg or ""):lower ():match ("^%s*(%a+)") or "";

		if (first == "watch") then
			local onoff = tostring (msg or ""):lower ():match ("^%s*%a+%s+(%a+)");
			gCBTapeOn = (onoff ~= "off");
			if (zc and zc.msg_atr) then
				zc.msg_atr (CBT ("Call Board: event tape ") .. (gCBTapeOn and CBT ("on") or CBT ("off")));
			end
			return;
		end

		if (first == "clear") then
			gCBTape    = {};
			gCBLastTip = nil;
			if (zc and zc.msg_atr) then zc.msg_atr (CBT ("Call Board: tape and tooltip cleared")); end
			return;
		end

		if (first == "" or first == "dump" or first == "all") then
			Atr_CB_Dump ("all");
			return;
		end

		if (first == "log" or first == "frames" or first == "tip"
		    or first == "npc" or first == "tape" or first == "weeks"
		    or first == "tree") then
			Atr_CB_Dump (first);
			return;
		end

		if (zc and zc.msg_atr) then
			zc.msg_atr (CBT ("usage: /atrcallboard  (full dump)  |  weeks  |  tree  |  log  |  frames  |  tip  |  npc  |  tape  |  watch on|off  |  clear"));
		end
	end
end
