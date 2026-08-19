-- LEDGER: a record of what you actually bought and sold -------------------------
--
-- BACKLOG item 7.  Auctionator knows a great deal about what things COST and
-- almost nothing about what YOU did: AUCTIONATOR_PRICING_HISTORY records the
-- prices you listed at, never what happened next, and nothing anywhere records a
-- purchase.  So "am I making money" is not answerable from anything stored.
-- This file is the missing record.
--
-- SCOPE, v1 (owner, 2026-08-19): AUCTION HOUSE ACTIVITY ONLY.  Vendor buy/sell
-- and the merchant window are a later pass -- one event source instead of five,
-- so this ships in one go rather than two.  The `src` tag ships anyway even
-- though only auction-house values are ever written to it, because adding it
-- later would leave every existing row with an unknowable source.
--
-- What v1 captures, and where from:
--
--   src = "buy"      Atr_Ledger_RecordBuy, from the buy loop's PlaceAuctionBid
--                    (AuctionatorBuy.lua).  The addon drives that loop itself, so
--                    it knows the item, stack and price it INTENDED to pay.
--   src = "post"     Atr_Ledger_RecordPost, on multi-sell confirmation
--                    (Auctionator.lua).  Carries the deposit, which has to be
--                    read at CLICK time -- see Atr_Ledger_NotePostIntent.
--
-- Still to come: the mail side (sale / expiry / cancellation), which needs the
-- mailbox, and the Ledger tab itself.  Rows accumulate from now regardless,
-- which is the point of landing the record first: a row written under the wrong
-- schema cannot be back-filled, and a row not written at all is gone.
--
-- THE ROW SHAPE is the expensive decision here, so it follows the four rules the
-- backlog settled before any of this was written:
--
--   1. INTENDED and DELIVERED are separate fields, never one.  The buy loop
--      knows what it ASKED for; what arrived is a different question and is
--      exactly what item 9 (bought a Grovewood Log, received a Grovewood Plank)
--      is about.  A row that records only "bought X" cannot answer it.  Where we
--      genuinely could not observe the delivered side it is left NIL -- nil is
--      honest, a copy of the intended value is a lie that looks like data.
--   2. MONEY IS COPPER, always, and the UNIT price is stored with the QUANTITY
--      rather than a total.  Every downstream question -- per-item margin,
--      restock cost -- needs the unit, and a total cannot be turned back into
--      one.  The Bazaar established the copper rule.
--   3. TIME IS A REAL TIMESTAMP, not a display string.  AUCTIONATOR_PRICING_HISTORY
--      packs its time through ToTightTime to keep the table small; this keeps raw
--      time() instead, because the Advisor (item 8) is the only consumer that
--      will ever want a series out of this and it will want ordering finer than
--      the day.  One integer per row is not what makes a saved-variables file
--      large (see item 13 for what does).
--   4. EVERY ROW CARRIES A SOURCE TAG.  One table with a `src` field, not seven
--      tables.  Being able to total across them is the whole value.
--
-- Storage: AUCTIONATOR_LEDGER, account-wide, declared in the .toc.  Account-wide
-- because a ledger split per character cannot answer "did this flip make money"
-- when you buy on one and sell on another, which is the normal way to play.

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function LZT (s)
	if (ZT) then return ZT (s); end
	return s;
end

-- Row cap.  The Hints DB caps its raw sample log at 500, but this is a RECORD
-- rather than a sample: pruning loses history the user may care about, so the
-- cap is generous and the rule is OLDEST FIRST -- never the mean database's
-- random eviction, which destroyed the ordering there and cannot be undone.
--
-- 2000 rows is roughly three months of heavy trading. At the ~120 bytes a row
-- serialises to that is about 240 KB, which is real but bounded, and small
-- beside the redundancy item 13 measures in the same file. The first prune says
-- so in chat rather than happening silently, because the alternative is a user
-- discovering their oldest records are gone at the moment they went looking.
local ATR_LEDGER_MAX_ROWS = 2000;
local gLedgerPruneTold    = false;

function Atr_Ledger_DB ()

	if (type (AUCTIONATOR_LEDGER) ~= "table") then AUCTIONATOR_LEDGER = {}; end
	if (type (AUCTIONATOR_LEDGER.rows) ~= "table") then AUCTIONATOR_LEDGER.rows = {}; end
	if (AUCTIONATOR_LEDGER.ver == nil) then AUCTIONATOR_LEDGER.ver = 1; end

	return AUCTIONATOR_LEDGER;
end

local function Atr_Ledger_ItemID (link)
	if (type (link) ~= "string" or zc == nil or zc.ItemIDfromLink == nil) then return nil; end
	return tonumber ((zc.ItemIDfromLink (link)));   -- extra parens: returns 3 values
end

-- Append one row.  `row` arrives with its src-specific fields already set; the
-- fields every row shares are stamped here so no caller can forget one.
function Atr_Ledger_Add (row)

	if (type (row) ~= "table" or row.src == nil) then return nil; end

	local db = Atr_Ledger_DB ();

	row.t   = row.t or (time and time()) or 0;
	row.who = row.who or (UnitName and UnitName ("player")) or nil;

	if (row.link and row.id == nil) then row.id = Atr_Ledger_ItemID (row.link); end

	tinsert (db.rows, row);

	-- oldest first, and say so once
	while (#db.rows > ATR_LEDGER_MAX_ROWS) do
		tremove (db.rows, 1);
		if (not gLedgerPruneTold) then
			gLedgerPruneTold = true;
			local s = string.format (LZT("Auctionator ledger: at its %d-row limit; the oldest rows are now being dropped as new ones arrive."), ATR_LEDGER_MAX_ROWS);
			if (zc and zc.msg_atr) then zc.msg_atr (s);
			elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
		end
	end

	return row;
end

-- BUY ---------------------------------------------------------------------
--
-- Called from the buy loop at the moment it issues PlaceAuctionBid, which is the
-- only moment the listing's own data is addressable ("list", index).  What this
-- records is the INTENDED purchase: the loop asked for this item at this price.
-- Whether that is what arrives in the mail is item 9's question, so the
-- delivered fields are deliberately left nil rather than assumed.
function Atr_Ledger_RecordBuy (listIndex, unitPrice)

	if (listIndex == nil or type (GetAuctionItemInfo) ~= "function") then return nil; end

	local name, _, count, quality, _, level, _, _, buyoutPrice = GetAuctionItemInfo ("list", listIndex);
	if (name == nil) then return nil; end

	local link = (type (GetAuctionItemLink) == "function") and GetAuctionItemLink ("list", listIndex) or nil;

	local qty = tonumber (count) or 1;
	if (qty < 1) then qty = 1; end

	-- unitPrice is what the loop matched on (per ITEM); buyoutPrice is the
	-- stack's total.  Prefer the stack total we can see, and derive the unit from
	-- it, so the row records what was actually paid rather than what was sought.
	local total = tonumber (buyoutPrice) or ((tonumber (unitPrice) or 0) * qty);

	return Atr_Ledger_Add ({
		src		= "buy",
		name	= name,
		link	= link,
		qty		= qty,
		unit	= math.floor (total / qty),
		quality	= quality,
		level	= level,
		-- delivered side: unobserved here by construction (see item 9)
	});
end

-- POST --------------------------------------------------------------------
--
-- Two halves, and they have to be two.  The DEPOSIT is only knowable while the
-- item is still in the sell slot, because CalculateAuctionDeposit reads that
-- slot -- but whether the auctions were actually created is only known later,
-- when the multi-sell run reports its last stack.  So the click notes the
-- intent, and the confirmation commits the rows.
--
-- An intent that never gets confirmed is simply dropped: the next click
-- overwrites it, and a post that failed should leave no row.
local gPendingPost = nil;

function Atr_Ledger_NotePostIntent (duration)

	local dep = 0;
	if (type (CalculateAuctionDeposit) == "function" and duration) then
		local ok, d = pcall (CalculateAuctionDeposit, duration);
		if (ok and tonumber (d)) then dep = tonumber (d); end
	end

	gPendingPost = { deposit = dep, duration = duration };
end

-- `stacks` is how many auctions actually went up: the multi-sell path knows its
-- own total, and the failure path knows how far it got.  The deposit recorded is
-- per-auction from the note above, multiplied by the stacks that really posted.
function Atr_Ledger_RecordPost (name, link, stackSize, stackPrice, stacks)

	if (name == nil) then return nil; end

	local qty   = tonumber (stackSize) or 1;
	local n     = tonumber (stacks) or 1;
	local price = tonumber (stackPrice) or 0;

	if (qty < 1) then qty = 1; end
	if (n   < 1) then n   = 1; end

	local dep = (gPendingPost and tonumber (gPendingPost.deposit) or 0) * n;
	local dur = gPendingPost and gPendingPost.duration or nil;

	gPendingPost = nil;

	return Atr_Ledger_Add ({
		src			= "post",
		name		= name,
		link		= link,
		qty			= qty * n,			-- items listed in total
		unit		= math.floor (price / qty),	-- asking price per item
		stacks		= n,
		stackSize	= qty,
		deposit		= dep,
		duration	= dur,
	});
end

-- READING IT --------------------------------------------------------------
--
-- No tab yet (that is the next pass), so this is how the record is inspected --
-- and how the capture above gets checked in game without waiting for the UI.
function Atr_Ledger_Summary (limit)

	local db   = Atr_Ledger_DB ();
	local rows = db.rows;
	local n    = #rows;

	limit = tonumber (limit) or 15;
	if (limit < 1) then limit = 1; end

	local function money (c)
		if (zc and zc.priceToMoneyString) then return zc.priceToMoneyString (c or 0); end
		return tostring (c or 0).."c";
	end

	local out = function (s)
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end

	if (n == 0) then
		out (LZT("Auctionator ledger: empty. It records auction-house buys and posts from now on."));
		return 0;
	end

	local spent, listed, deposits = 0, 0, 0;
	local i;
	for i = 1, n do
		local r = rows[i];
		if (r.src == "buy")  then spent  = spent  + ((r.unit or 0) * (r.qty or 0)); end
		if (r.src == "post") then listed = listed + ((r.unit or 0) * (r.qty or 0));
								  deposits = deposits + (r.deposit or 0); end
	end

	out (string.format (LZT("Auctionator ledger: %d rows.  Bought %s, listed %s, deposits %s."),
		 n, money (spent), money (listed), money (deposits)));

	local first = n - limit + 1;
	if (first < 1) then first = 1; end

	for i = first, n do
		local r = rows[i];
		local when = (date and r.t) and date ("%m-%d %H:%M", r.t) or "?";
		out (string.format ("  |cff888888%s|r  %-6s %s x%d @ %s%s",
			 when, tostring (r.src), tostring (r.link or r.name), r.qty or 0, money (r.unit),
			 (r.deposit and r.deposit > 0) and ("  |cff888888dep "..money (r.deposit).."|r") or ""));
	end

	return n;
end

-- Global so it is macro-able, and because the tab will want it later.
function Atr_Ledger_Clear ()
	AUCTIONATOR_LEDGER = { ver = 1, rows = {} };
	gLedgerPruneTold = false;
	if (zc and zc.msg_atr) then zc.msg_atr (LZT("Auctionator ledger cleared.")); end
end

if (SlashCmdList) then
	SLASH_ATRLEDGER1 = "/atrledger";
	SlashCmdList["ATRLEDGER"] = function (msg)
		msg = tostring (msg or ""):lower():gsub ("^%s+", ""):gsub ("%s+$", "");
		if (msg == "clear") then
			Atr_Ledger_Clear ();
		else
			Atr_Ledger_Summary (tonumber (msg));
		end
	end
end

-- THE MAIL SIDE (stage 2) -------------------------------------------------
--
-- Sale, expiry, cancellation and the delivery of things you bought all arrive
-- as mail, so this is where the ledger learns what came BACK.
--
-- DESIGNED AROUND A MASS-OPENER.  The owner opens mail with Postal's "Open All"
-- (2026-08-19), and that rules out the obvious implementation:
--
--   * NEVER key on the inbox index.  Taking a mail re-indexes everything after
--     it, so an index read one frame names a different mail the next, and 3.3.5
--     gives a mail no stable id at all.
--   * Identity therefore comes from CONTENT -- sender, subject, money, the
--     attachment and its count -- and duplicates are real: one Open All in the
--     owner's log shows three identical "Auction won: Linen Cloth" mails from
--     one seller.  So identity alone cannot count; it has to be counted as a
--     MULTISET.
--   * MAIL_INBOX_UPDATE arrives in storms while Postal works, the same way
--     MERCHANT_UPDATE and TRADE_SKILL_UPDATE do, so the sweep is debounced the
--     way AuctionatorFinderMerchant.lua debounces its harvest.
--   * A mail can vanish between being seen and being read, so every read is
--     tolerant and a missing one is a no-op rather than a half-written row.
--
-- HOW COUNTING WORKS.  Each sweep builds the multiset of auction mails currently
-- in the inbox.  A key seen MORE times than last sweep gained that many mails,
-- and those become rows; a key seen fewer times lost mails to Postal, which is
-- not an event at all.  The previous multiset is persisted, because an unread
-- mail is still there after a relog and must not be counted twice.
--
-- It is kept PER CHARACTER inside the account-wide ledger, because an inbox is.
--
-- What this cannot see: a mail that arrives and is taken between two sweeps.
-- The first sweep runs on the first MAIL_INBOX_UPDATE after the mailbox opens,
-- before Postal's own timer starts taking, so the realistic gap is a mail that
-- lands while you are standing at the box.

local function Atr_Ledger_SubjectPattern (fmt, fallback)

	local f = (type (fmt) == "string" and fmt ~= "") and fmt or fallback;
	if (type (f) ~= "string" or f == "") then return nil; end

	-- escape every magic character, then re-open the single %s the format carries
	local pat = f:gsub ("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1");
	pat = pat:gsub ("%%%%s", "(.+)");

	return "^"..pat;
end

-- Read the client's own subject formats, exactly as the recipe filter reads
-- ITEM_SPELL_KNOWN: a localised or re-worded client still matches, and the
-- English literal is only the last resort.
local gLedgerSubjects = nil;

local function Atr_Ledger_Subjects ()

	if (gLedgerSubjects) then return gLedgerSubjects; end

	gLedgerSubjects = {
		-- src        pattern built from the client global
		{ src = "won",    pat = Atr_Ledger_SubjectPattern (_G["AUCTION_WON_MAIL_SUBJECT"],     "Auction won: %s") },
		{ src = "sale",   pat = Atr_Ledger_SubjectPattern (_G["AUCTION_SOLD_MAIL_SUBJECT"],    "Auction successful: %s") },
		{ src = "expire", pat = Atr_Ledger_SubjectPattern (_G["AUCTION_EXPIRED_MAIL_SUBJECT"], "Auction expired: %s") },
		{ src = "cancel", pat = Atr_Ledger_SubjectPattern (_G["AUCTION_REMOVED_MAIL_SUBJECT"], "Auction cancelled: %s") },
	};

	return gLedgerSubjects;
end

-- Which kind of auction mail this is, and the item name in its subject.
-- Returns nil for anything that is not auction mail -- including "Outbid on %s",
-- which returns your own bid and is not a trade.
function Atr_Ledger_ClassifySubject (subject)

	if (type (subject) ~= "string" or subject == "") then return nil; end

	local subs = Atr_Ledger_Subjects ();
	local i;
	for i = 1, #subs do
		local e = subs[i];
		if (e.pat) then
			local name = subject:match (e.pat);
			if (name) then return e.src, name; end
		end
	end

	return nil;
end

local function Atr_Ledger_SeenDB ()

	local db  = Atr_Ledger_DB ();
	local who = (UnitName and UnitName ("player")) or "?";

	if (type (db.seen) ~= "table") then db.seen = {}; end
	if (type (db.seen[who]) ~= "table") then db.seen[who] = {}; end

	return db.seen[who];
end

-- The multiset key. Money and the attachment's count are in it because they are
-- what distinguishes two otherwise identical sales; the mail's own index and its
-- remaining days deliberately are not, since both move on their own.
local function Atr_Ledger_MailKey (sender, subject, money, itemName, itemCount)
	return table.concat ({ tostring (sender or "?"), tostring (subject or "?"),
						   tostring (money or 0), tostring (itemName or ""),
						   tostring (itemCount or 0) }, "\1");
end

-- Walk the inbox once and turn anything newly arrived into rows.
-- Returns the number of rows added.
function Atr_Ledger_SweepInbox ()

	if (type (GetInboxNumItems) ~= "function" or type (GetInboxHeaderInfo) ~= "function") then return 0; end

	local n = GetInboxNumItems () or 0;

	local cur, meta = {}, {};

	local i;
	for i = 1, n do

		local ok, _, _, sender, subject, money, _, _, itemCount = pcall (GetInboxHeaderInfo, i);

		if (ok and subject) then

			local src, subjectItem = Atr_Ledger_ClassifySubject (subject);

			if (src) then
				-- The invoice is the exact record where one exists: it carries the
				-- bid, the buyout, the deposit and the auction house's cut, which
				-- the header's lump of money cannot be taken apart into.
				local iType, iName, iPlayer, iBid, iBuyout, iDeposit, iCut;
				if (type (GetInboxInvoiceInfo) == "function") then
					local okI, a, b, c, d, e, f, g = pcall (GetInboxInvoiceInfo, i);
					if (okI) then iType, iName, iPlayer, iBid, iBuyout, iDeposit, iCut = a, b, c, d, e, f, g; end
				end

				local link, aName, aCount;
				if (type (GetInboxItemLink) == "function") then
					local okL, l = pcall (GetInboxItemLink, i, 1);
					if (okL) then link = l; end
				end
				if (type (GetInboxItem) == "function") then
					local okA, nm, _, ct = pcall (GetInboxItem, i, 1);
					if (okA) then aName, aCount = nm, ct; end
				end

				local key = Atr_Ledger_MailKey (sender, subject, money, aName or subjectItem, aCount or itemCount);

				cur[key] = (cur[key] or 0) + 1;

				if (meta[key] == nil) then
					meta[key] = {
						src		= src,
						name	= aName or iName or subjectItem,
						link	= link,
						qty		= tonumber (aCount) or nil,
						money	= tonumber (money) or 0,
						who2	= iPlayer or sender,		-- the other party
						bid		= tonumber (iBid) or nil,
						buyout	= tonumber (iBuyout) or nil,
						deposit	= tonumber (iDeposit) or nil,
						cut		= tonumber (iCut) or nil,
					};
				end
			end
		end
	end

	-- Diff against the last sweep.  More of a key than last time means that many
	-- new mails; fewer means Postal took some, which is not an event.
	local seen  = Atr_Ledger_SeenDB ();
	local added = 0;

	local key, c;
	for key, c in pairs (cur) do
		local prev = tonumber (seen[key]) or 0;
		if (c > prev) then
			local m = meta[key];
			local k;
			for k = 1, (c - prev) do
				Atr_Ledger_Add ({
					src		= m.src,
					name	= m.name,
					link	= m.link,
					qty		= m.qty,
					-- A sale's money is the NET already: the header's money is what
					-- actually lands in your bags. bid/buyout/deposit/cut keep the
					-- parts so a later report does not have to guess at them.
					unit	= (m.qty and m.qty > 0 and m.money > 0) and math.floor (m.money / m.qty) or nil,
					money	= m.money,
					bid		= m.bid,
					buyout	= m.buyout,
					deposit	= m.deposit,
					cut		= m.cut,
					party	= m.who2,
				});
				added = added + 1;
			end
		end
	end

	-- Replace wholesale: keys that vanished were taken, and must be countable
	-- again if the same mail ever reappears.
	local fresh = {};
	for key, c in pairs (cur) do fresh[key] = c; end

	local db  = Atr_Ledger_DB ();
	local me  = (UnitName and UnitName ("player")) or "?";
	db.seen[me] = fresh;

	return added;
end

-- Own event frame, guarded so the file still loads under a bare interpreter.
if (type (CreateFrame) == "function") then

	local lf = CreateFrame ("Frame", "Atr_Ledger_MailWatch", UIParent);

	lf:RegisterEvent ("MAIL_SHOW");
	lf:RegisterEvent ("MAIL_INBOX_UPDATE");
	lf:RegisterEvent ("MAIL_CLOSED");

	local DELAY    = 0.3;      -- quiet before re-sweeping, as the merchant scan does
	local elapsed  = 0;
	local sweptYet = false;    -- the first update after opening is swept at once

	lf:Hide ();                -- OnUpdate only ticks while shown

	lf:SetScript ("OnEvent", function (self, event)

		if (event == "MAIL_SHOW") then
			sweptYet = false;
			return;
		end

		if (event == "MAIL_CLOSED") then
			self:Hide (); elapsed = 0; sweptYet = false;
			return;
		end

		-- MAIL_INBOX_UPDATE.  Sweep the FIRST one immediately: Postal starts
		-- taking on its own timer and a debounced first pass could miss whatever
		-- it removes in the meantime.  Everything after that is debounced,
		-- because the burst while it works is exactly the storm the merchant
		-- scan's comment describes.
		if (not sweptYet) then
			sweptYet = true;
			pcall (Atr_Ledger_SweepInbox);
			return;
		end

		elapsed = 0;
		self:Show ();
	end);

	lf:SetScript ("OnUpdate", function (self, dt)
		elapsed = elapsed + (dt or 0);
		if (elapsed >= DELAY) then
			elapsed = 0;
			self:Hide ();
			pcall (Atr_Ledger_SweepInbox);
		end
	end);
end
