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
-- Both of those landed the same day: the mail side (sale / expiry / cancellation,
-- swept off the mailbox) and the Ledger tab.  Rows accumulated from the first
-- stage regardless, which was the point of landing the record before either of
-- them: a row written under the wrong schema cannot be back-filled, and a row not
-- written at all is gone.  What reads the rows back as money is
-- Atr_Ledger_ItemTotals below, for the Analysis tab's second view (item 8, D).
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

-- WHAT YOU ACTUALLY MADE, PER ITEM -----------------------------------------
--
-- BACKLOG item 8, group D.  Everything else the Analysis tab shows is inferred
-- from listings that vanished between two scans; these are the only numbers on
-- it that are not estimates, because they are money that actually moved.
--
-- AGGREGATED PER ITEM NAME, deliberately, and never per transaction.  A
-- per-transaction margin needs each purchase paired to its delivery, and the
-- mail carries no reference to the auction it came from -- that is item 9's
-- unsolved problem, and a Postal "open all" delivers a batch at once, which is
-- exactly when the ordering is least reliable.  Total paid for X against total
-- received for X needs no pairing at all, so this sidesteps it rather than
-- waiting on it.
--
-- WHERE EACH NUMBER COMES FROM, and why not the obvious field:
--
--   GOT      the invoice's bid MINUS the auction house's cut, not the mail's
--            `money`.  The header money is what lands in your bags, which on a
--            successful auction also carries the returned deposit -- counting
--            that as proceeds would report your own deposit back as profit.
--            `money` is the fallback, for a mail that carried no invoice.
--   PAID     `won` rows, which are deliveries carrying a BUYER invoice, so a
--            purchase made by hand in the auction house window is counted too
--            and not just the ones the buy loop drove.  An item with no priced
--            `won` row falls back to its `buy` rows -- what the loop intended --
--            so a mail sweep that missed its window understates rather than
--            disappears.  The two are never summed: an addon purchase writes
--            BOTH a buy and a won row, and adding them would double it.
--   DEPOSITS never netted into the margin.  Whether a sale's mail hands the
--            deposit back inside `money` is exactly the question the
--            bid-minus-cut rule above avoids having to answer, and a deposit on
--            a listing that is still up is not lost yet either way.
--
-- SELL-THROUGH counts sold against sold + expired.  A cancelled listing is not
-- the market's verdict on your price, it is yours, so it is not in the
-- denominator.
--
-- The window is whatever the ledger still holds: rows are pruned oldest-first at
-- ATR_LEDGER_MAX_ROWS, so `from` is returned with the totals and the tab says so
-- rather than presenting a window as an all-time figure.
function Atr_Ledger_ItemTotals ()

	local db   = Atr_Ledger_DB ();
	local rows = db.rows;

	local byName = {};
	local list   = {};

	local function rec (name)

		if (name == nil or name == "") then return nil; end

		local r = byName[name];
		if (r == nil) then
			r = { name = name,
				  boughtQty = 0, paid = 0, intentQty = 0, intentPaid = 0,
				  soldQty = 0, got = 0,
				  postedQty = 0, deposits = 0, expiredQty = 0, cancelledQty = 0 };
			byName[name] = r;
			tinsert (list, r);
		end
		return r;
	end

	local i;
	for i = 1, #rows do

		local row = rows[i];
		local r   = rec (row.name);

		if (r) then

			local qty = tonumber (row.qty) or 0;

			if (row.src == "buy") then
				r.intentQty  = r.intentQty + qty;
				r.intentPaid = r.intentPaid + (tonumber (row.unit) or 0) * qty;
				if (r.link == nil) then r.link = row.link; end

			elseif (row.src == "won") then
				r.boughtQty = r.boughtQty + qty;
				r.paid      = r.paid + (tonumber (row.bid) or 0);
				if (r.link == nil) then r.link = row.link; end

			elseif (row.src == "post") then
				r.postedQty = r.postedQty + qty;
				r.deposits  = r.deposits + (tonumber (row.deposit) or 0);
				if (row.unit) then r.lastPostUnit = tonumber (row.unit); end
				if (r.link == nil) then r.link = row.link; end

			elseif (row.src == "sale") then
				r.soldQty = r.soldQty + qty;
				if (row.bid and row.cut) then
					r.got = r.got + (row.bid - row.cut);
				else
					r.got = r.got + (tonumber (row.money) or 0);
				end
				if (r.link == nil) then r.link = row.link; end

			elseif (row.src == "expire") then
				r.expiredQty = r.expiredQty + qty;

			elseif (row.src == "cancel") then
				r.cancelledQty = r.cancelledQty + qty;
			end
		end
	end

	local tot = { paid = 0, got = 0, margin = 0, deposits = 0, tied = 0, tiedQty = 0,
				  rows = #rows, items = #list, from = rows[1] and rows[1].t or nil };

	for i = 1, #list do

		local r = list[i];

		-- a won row with no invoice prices at nothing, so "we saw a delivery" is
		-- not on its own a reason to believe the intent record is the worse one
		if (r.paid <= 0 and r.intentPaid > 0) then
			r.paid			= r.intentPaid;
			r.boughtQty		= r.intentQty;
			r.paidFromIntent = true;
		end

		r.margin = r.got - r.paid;

		local resolved = r.soldQty + r.expiredQty;
		if (resolved > 0) then r.sellThrough = r.soldQty / resolved; end

		r.outstandingQty = r.postedQty - r.soldQty - r.expiredQty - r.cancelledQty;
		if (r.outstandingQty < 0) then r.outstandingQty = 0; end
		r.tied = r.outstandingQty * (r.lastPostUnit or 0);


		tot.paid		= tot.paid + r.paid;
		tot.got			= tot.got + r.got;
		tot.deposits	= tot.deposits + r.deposits;
		tot.tied		= tot.tied + r.tied;
		tot.tiedQty		= tot.tiedQty + r.outstandingQty;
	end

	tot.margin = tot.got - tot.paid;

	return list, tot;
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

-- THE TAB (stage 3) -------------------------------------------------------
--
-- Own panel on its own main tab, the way the Finder and the Bazaar do it
-- (FRAMEWORK.md §4, "World 2"): the shared Auctionator panel is built around one
-- scanned ITEM, and a ledger is not about an item -- it is about you. The 15
-- wiring sites in Auctionator.lua are tagged `-- LEDGER_TAB`, the same census the
-- Bazaar left behind.
--
-- The name was taken. Tab 2 of the Current/Ledger strip was called "Ledger" but
-- shows the price HISTORY of the scanned item, which is what Atr_ShowHistory
-- already titles its own column -- the label was the odd one out. Renamed to
-- History (Auctionator.xml), which frees the name for the thing that is actually
-- a ledger.

local LDG_NUM_ROWS = 16;
local LDG_ROW_H    = 20;

-- THE TABLE IS MEASURED, NOT ASSUMED 768 WIDE (BACKLOG item 2) --------------
--
-- This panel was built to Blizzard's 768px auction house minus its insets, and
-- every width in it was a constant: a 738 panel, a 690 scroll frame, 660 rows and
-- five columns at hand-counted offsets.  Ascension's window is wider, so the
-- whole table sat left with a band of dead backdrop beyond its right edge.
--
-- The Analysis tab hit this exact bug first and the fix is ported from it rather
-- than reinvented (AuctionatorAnalysis.lua, An_LayoutCols and Atr_An_Init): read
-- the real window width, derive everything from it, and hand the slack to the
-- column that can use it.  Both tabs now compute their panel the same way, which
-- is the point -- two answers to "how wide is the auction house" is how one of
-- them ends up wrong again.
--
-- THE SCROLL BAR'S LANE COMES OFF THE PANEL, NOT OFF THE ROWS.  A
-- FauxScrollFrame's bar is anchored to the scroll frame's TOPRIGHT and hangs
-- OUTSIDE it, so reserving room inside the rows as well spends it twice and
-- leaves the table short of the right edge by that much again.  That is the
-- mistake the Analysis comment records; it is not repeated here.
local LDG_HEAD_X0 = 14;		-- the scroll frame's own inset from the panel's left
local LDG_LEAD    = 6;		-- gap before the first column, inside a row
local LDG_COL_GAP = 4;		-- gap between columns
local LDG_SB_LANE = 26;		-- what the scroll bar needs to the RIGHT of the rows

-- A placeholder: Atr_Ledger_Init recomputes it from the real window.
local LDG_ROW_W = 660;

-- ITEM IS THE ONLY COLUMN THAT GROWS, and that is a judgement rather than an
-- accident.  A date is a date, a quantity is two characters and money is money --
-- widening any of them buys nothing.  An item name is the one cell here that
-- gets truncated on a narrow window, and on this server it is also the longest
-- thing in the table, so the slack goes to it whole.
--
-- `w` is a minimum, `grow` a share of what is left over, `just` the alignment --
-- the same three fields the Analysis columns carry, so the two read alike.
local LDG_COLS = {
	{ key = "when",  head = "When",  w = 88,  grow = 0 },
	{ key = "what",  head = "What",  w = 86,  grow = 0 },
	{ key = "item",  head = "Item",  w = 300, grow = 1 },
	{ key = "qty",   head = "Qty",   w = 44,  grow = 0 },
	{ key = "money", head = "Money", w = 120, grow = 0, just = "RIGHT" },
};

-- Fills in each column's computed x (`cx`) and width (`cw`) for a row of `rowW`.
-- A stripped-down An_LayoutCols: no delete lane and no leading tick lane, because
-- this table has neither.
local function Ldg_LayoutCols (cols, rowW)

	local base, grow, last = 0, 0, nil;
	local i, c;
	for i, c in ipairs (cols) do
		base = base + c.w;
		if ((c.grow or 0) > 0) then grow = grow + c.grow; last = i; end
	end

	local slack = rowW - LDG_LEAD - LDG_COL_GAP * (#cols - 1) - base;
	if (slack < 0 or grow == 0) then slack = 0; end		-- narrow window: minimums win

	local x, handed = LDG_LEAD, 0;
	for i, c in ipairs (cols) do
		local add = 0;
		if (slack > 0 and (c.grow or 0) > 0) then
			if (i == last) then
				add = slack - handed;			-- the last grower absorbs the rounding
			else
				add = math.floor (slack * c.grow / grow);
				handed = handed + add;
			end
		end
		c.cw = c.w + add;
		c.cx = x;
		x = x + c.cw + LDG_COL_GAP;
	end
end

-- What each src reads as, and the colour it carries. Money OUT is what you
-- spent, money IN is what came back; expiry and cancellation move no money at
-- all and must not be coloured as though they did.
local LDG_SRC = {
	buy		= { text = "Bought",	colour = "|cffff8080" },
	post	= { text = "Listed",	colour = "|cffcccccc" },
	won		= { text = "Received",	colour = "|cff80c0ff" },
	sale	= { text = "Sold",		colour = "|cff80ff80" },
	expire	= { text = "Expired",	colour = "|cff888888" },
	cancel	= { text = "Cancelled",	colour = "|cff888888" },
};

local function Ldg_Money (c)
	if (c == nil or c == 0) then return "|cff666666--|r"; end
	if (zc and zc.priceToMoneyString) then return zc.priceToMoneyString (c); end
	return tostring (c);
end

-- Newest first: a ledger is read from the end.
local function Ldg_Rows ()
	local db = Atr_Ledger_DB ();
	return db.rows or {};
end

-- THE FILTER (owner, 2026-08-22: a filter box, top left, where the Analysis tab
-- keeps its own).  Item name only, matched the way An_PassesFilter matches --
-- lowercased, plain `find`, no patterns -- so the two boxes behave identically
-- and a bracket typed into either is a bracket rather than a pattern error.
local gLdg_Filter = "";

-- The ROW's own name, not its link: a link is "|cff...|Hitem:...|h[Copper Ore]|h|r"
-- and filtering that would match on colour codes and item ids.  Where a row has
-- only a link, the name inside the brackets is what somebody would have typed.
local function Ldg_RowName (r)

	if (type (r) ~= "table") then return nil; end
	if (type (r.name) == "string" and r.name ~= "") then return r.name; end

	if (type (r.link) == "string") then return r.link:match ("%[(.-)%]"); end

	return nil;
end

local function Ldg_PassesFilter (r)

	if (gLdg_Filter == "") then return true; end

	local name = Ldg_RowName (r);
	if (name == nil) then return false; end

	return (string.find (string.lower (name), gLdg_Filter, 1, true) ~= nil);
end

-- What the table DRAWS, which is not what the ledger HOLDS.
--
-- Deliberately not folded into Ldg_Rows, and this is the trap worth naming: the
-- Clear button's confirmation counts rows with #Ldg_Rows(), and Clear deletes
-- the whole ledger regardless of what is filtered.  A filtered Ldg_Rows would
-- have made the popup ask "Delete all 3 ledger rows?" while deleting 412.
local function Ldg_VisibleRows ()

	if (gLdg_Filter == "") then return Ldg_Rows (); end

	local out = {};
	local src = Ldg_Rows ();

	local i;
	for i = 1, #src do
		if (Ldg_PassesFilter (src[i])) then table.insert (out, src[i]); end
	end

	return out;
end

local function Ldg_SetFilter (text)

	local f = tostring (text or "");
	f = f:gsub ("^%s+", ""):gsub ("%s+$", "");
	f = string.lower (f);

	if (f == gLdg_Filter) then return; end

	gLdg_Filter = f;

	-- a narrower list under an old scroll offset draws as a page of nothing --
	-- the same reason An_SetFilter scrolls to the top
	if (FauxScrollFrame_SetOffset and Atr_Ledger_ScrollFrame) then
		FauxScrollFrame_SetOffset (Atr_Ledger_ScrollFrame, 0);
	end
	if (Atr_Ledger_ScrollFrameScrollBar and Atr_Ledger_ScrollFrameScrollBar.SetValue) then
		Atr_Ledger_ScrollFrameScrollBar:SetValue (0);
	end

	Atr_Ledger_Redisplay ();
end

function Atr_Ledger_Redisplay ()

	if (not Atr_Ledger_Panel or not Atr_Ledger_Panel:IsShown()) then return; end

	local rows = Ldg_VisibleRows ();
	local n    = #rows;

	if (FauxScrollFrame_Update) then
		FauxScrollFrame_Update (Atr_Ledger_ScrollFrame, n, LDG_NUM_ROWS, LDG_ROW_H);
	end

	local offset = (FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset (Atr_Ledger_ScrollFrame)) or 0;

	local i;
	for i = 1, LDG_NUM_ROWS do

		local line = _G["Atr_Ledger_Row"..i];
		if (line) then

			-- rows are stored oldest-first and read newest-first
			local r = rows[n - (offset + i - 1)];

			if (r == nil) then
				line:Hide();
			else
				local kind = LDG_SRC[r.src] or { text = tostring (r.src), colour = "|cffffffff" };

				line.when:SetText ((date and r.t) and date ("%m-%d %H:%M", r.t) or "");
				line.what:SetText (kind.colour..LZT(kind.text).."|r");
				line.item:SetText (r.link or r.name or "?");
				line.qty:SetText  (r.qty and ("x"..r.qty) or "");

				-- One money column, and it says which DIRECTION the money went,
				-- because a ledger that shows a sale and a purchase in the same
				-- colour is worse than one that shows neither.
				if (r.src == "sale") then
					line.money:SetText ("|cff80ff80+"..Ldg_Money (r.money).."|r");
				elseif (r.src == "buy") then
					line.money:SetText ("|cffff8080-"..Ldg_Money ((r.unit or 0) * (r.qty or 0)).."|r");
				elseif (r.src == "post") then
					line.money:SetText (Ldg_Money ((r.unit or 0) * (r.qty or 0)));
				else
					line.money:SetText (Ldg_Money (nil));
				end

				line.rec = r;
				line:Show();
			end
		end
	end

	-- The totals line, and the honesty rule this whole item turns on: v1 covers
	-- AUCTION HOUSE activity only, so vendor sales are ABSENT, not zero. It says
	-- "auction house" rather than "profit" for exactly that reason -- see the
	-- scope note on BACKLOG item 7.
	local spent, back, deposits = 0, 0, 0;
	for i = 1, n do
		local r = rows[i];
		if (r.src == "buy")  then spent = spent + ((r.unit or 0) * (r.qty or 0)); end
		if (r.src == "sale") then back  = back  + (r.money or 0); end
		if (r.src == "post") then deposits = deposits + (r.deposit or 0); end
	end

	if (Atr_Ledger_Totals) then

		-- THE TOTALS FOLLOW THE FILTER, and say so.  Money summed over the rows
		-- on screen is the useful number -- "what did I spend on Saronite" is the
		-- question a filter is typed to ask -- but "412 rows, out 900g" printed
		-- under three visible rows would be read as the whole ledger's, so the
		-- count names both.
		local count;
		if (gLdg_Filter == "") then
			count = string.format (LZT("%d rows"), n);
		else
			count = string.format (LZT("%d of %d rows"), n, #Ldg_Rows ());
		end

		Atr_Ledger_Totals:SetText (string.format (
			LZT("%s   |   auction house: out %s, in %s, deposits %s"),
			count, Ldg_Money (spent), Ldg_Money (back), Ldg_Money (deposits)));
	end
end

function Atr_Ledger_OnTabClick (index)

	if (Atr_Ledger_Panel == nil) then return; end

	if (ATR_LEDGER_TAB and Atr_FindTabIndex and index == Atr_FindTabIndex (ATR_LEDGER_TAB)) then
		Atr_Ledger_Panel:Show();
		Atr_Ledger_Redisplay ();
	else
		Atr_Ledger_Panel:Hide();
	end
end

function Atr_Ledger_Init ()

	if (Atr_Ledger_Panel or type (CreateFrame) ~= "function") then return; end

	-- Measured, exactly as Atr_An_Init does it: the panel starts 10 in from the
	-- window's left and ends where the backdrop does, 12 in from its right, so it
	-- IS the content area and anything anchored right is genuinely right.  The
	-- height is left alone -- it already matches.  The < 600 guard is the
	-- not-laid-out-yet case, where GetWidth can come back as something useless.
	local frameW = 768;
	if (AuctionFrame and AuctionFrame.GetWidth) then frameW = AuctionFrame:GetWidth() or 768; end
	if (frameW < 600) then frameW = 768; end

	local panelW = math.floor (frameW) - 22;

	local panel = CreateFrame ("Frame", "Atr_Ledger_Panel", AuctionFrame);
	panel:SetSize (panelW, 447);
	panel:SetPoint ("TOPLEFT", 10, 0);
	panel:Hide();

	-- Rows are the full scroll width; the bar gets LDG_SB_LANE beyond it, and 4
	-- more keeps it off the backdrop's edge.
	local scrollW = panelW - LDG_HEAD_X0 - LDG_SB_LANE - 4;
	LDG_ROW_W = scrollW;
	Ldg_LayoutCols (LDG_COLS, LDG_ROW_W);

	local bg = panel:CreateTexture (nil, "BACKGROUND");
	bg:SetTexture (0, 0, 0, 0.85);
	bg:SetPoint ("TOPLEFT", 14, -70);
	bg:SetPoint ("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -12, 28);

	local title = panel:CreateFontString (nil, "BACKGROUND", "GameFontNormal");
	title:SetPoint ("TOP", -10, -18);
	title:SetText ("Auctionator - "..LZT("Ledger"));

	-- Centred under the title rather than at the panel's left edge, where it ran
	-- along the top of the auction house's character portrait.  Anchored to the
	-- title itself so it follows if that ever moves.
	local note = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	note:SetPoint ("TOP", title, "BOTTOM", 0, -4);
	note:SetText (LZT("Auction house activity. Vendor sales are not recorded yet."));

	-- THE FILTER BOX (owner, 2026-08-22: "add a filter box, top left area (same
	-- position as Analysis tab)").  The same coordinates as Atr_An_FilterBox, and
	-- they transfer exactly because the two panels are laid out identically --
	-- both TOPLEFT (10, 0), both with their dark backdrop starting at -70.
	--
	-- x=72/76 rather than the 24 that looks like the left margin: at 24 both the
	-- label and the box run under the auction house's character portrait, which
	-- is drawn over them.  The Analysis tab's own comment records that; this is
	-- the second tab to inherit the answer rather than rediscover it.
	local filtLabel = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	filtLabel:SetPoint ("TOPLEFT", 72, -40);
	filtLabel:SetText (LZT("Filter"));

	local filtBox = CreateFrame ("EditBox", "Atr_Ledger_FilterBox", panel, "InputBoxTemplate");
	filtBox:SetSize (90, 20);
	filtBox:SetPoint ("TOPLEFT", 76, -52);
	filtBox:SetAutoFocus (false);
	filtBox:SetMaxBytes (96);

	-- OnTextChanged rather than OnEnterPressed: a filter you have to confirm is
	-- a search box.  The Analysis box works this way and so does this one.
	local rewriting = false;

	filtBox:SetScript ("OnTextChanged", function (self)

		if (rewriting) then return; end

		local txt = self:GetText() or "";

		-- a shift-clicked link arrives whole; filter on the name anybody would
		-- have typed.  The rewrite re-enters this script, hence the flag.
		local name = txt:match ("%[(.-)%]");
		if (name) then
			rewriting = true;
			self:SetText (name);
			rewriting = false;
			txt = name;
		end

		Ldg_SetFilter (txt);
	end);

	filtBox:SetScript ("OnEnterPressed", function (self) self:ClearFocus(); end);
	filtBox:SetScript ("OnEscapePressed", function (self)
		self:SetText ("");			-- OnTextChanged clears the filter with it
		self:ClearFocus();
	end);

	-- Column headings, from the same table the row cells come from.  They used to
	-- be five hand-counted numbers that had to be kept in step with five more on
	-- the rows below -- a heading is just a cell's own x shifted by the scroll
	-- frame's inset, so it is computed rather than remembered.
	local i, c;
	for i, c in ipairs (LDG_COLS) do
		local fs = panel:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
		fs:SetPoint ("TOPLEFT", LDG_HEAD_X0 + c.cx, -74);
		fs:SetText (LZT(c.head));
	end

	-- Created BEFORE the rows on purpose: sibling frames draw in creation order,
	-- so building the scroll first leaves the rows on top of it.  The other way
	-- round the scrollbar covers the money column and the rows stop taking mouse.
	local scroll = CreateFrame ("ScrollFrame", "Atr_Ledger_ScrollFrame", panel, "FauxScrollFrameTemplate");
	scroll:SetPoint ("TOPLEFT", LDG_HEAD_X0, -92);
	scroll:SetSize (scrollW, LDG_NUM_ROWS * LDG_ROW_H);
	scroll:SetScript ("OnVerticalScroll", function (self, offset)
		if (FauxScrollFrame_OnVerticalScroll) then
			FauxScrollFrame_OnVerticalScroll (self, offset, LDG_ROW_H, Atr_Ledger_Redisplay);
		end
	end);

	local rowsHolder = CreateFrame ("Frame", nil, panel);
	rowsHolder:SetPoint ("TOPLEFT", LDG_HEAD_X0, -92);
	rowsHolder:SetSize (LDG_ROW_W, LDG_NUM_ROWS * LDG_ROW_H);

	for i = 1, LDG_NUM_ROWS do

		local line = CreateFrame ("Button", "Atr_Ledger_Row"..i, rowsHolder);
		line:SetSize (LDG_ROW_W, LDG_ROW_H);
		line:SetPoint ("TOPLEFT", 0, -(i - 1) * LDG_ROW_H);

		-- Keyed off LDG_COLS, so a cell and its heading cannot drift apart: both
		-- read the same cx/cw.  The field names are unchanged, which is what keeps
		-- Atr_Ledger_Redisplay's line.when / line.what / ... working untouched.
		local c;
		for _, c in ipairs (LDG_COLS) do
			local fs = line:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			fs:SetPoint ("LEFT", c.cx, 0);
			fs:SetWidth (c.cw);
			fs:SetJustifyH (c.just or "LEFT");
			line[c.key] = fs;
		end

		-- the row's item tooltip, when the row still carries a link
		line:SetScript ("OnEnter", function (self)
			if (self.rec and self.rec.link and GameTooltip) then
				GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
				GameTooltip:SetHyperlink (self.rec.link);
				GameTooltip:Show();
			end
		end);
		line:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		line:Hide();
	end

	local totals = panel:CreateFontString ("Atr_Ledger_Totals", "ARTWORK", "GameFontNormalSmall");
	totals:SetPoint ("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 34);
	totals:SetText ("");

	-- TOP RIGHT, UNDER THE CLOSE BUTTON (BACKLOG item 3, owner's placement).  It
	-- sat at the panel's BOTTOMRIGHT, which on the Analysis tab is where the
	-- tab-level ACTION button lives (Rescan) -- and Clear is not that kind of
	-- button.  Up here it is out of the way of the table and reads as chrome,
	-- which is what a destructive control should look like.
	--
	-- The y clears Blizzard's close button (32px from the frame's top) and stops
	-- above the dark backdrop, which starts at -70.
	local clear = CreateFrame ("Button", "Atr_Ledger_ClearButton", panel, "UIPanelButtonTemplate");
	clear:SetSize (70, 22);
	clear:SetPoint ("TOPRIGHT", panel, "TOPRIGHT", -16, -46);
	clear:SetText (LZT("Clear"));

	-- ASK FIRST, AND THIS IS THE HALF OF THE ITEM THAT MATTERS.  One click used to
	-- destroy the ledger outright.  Every other store in this addon regrows by
	-- scanning -- prices, vendor learning, the recipe book, the market history in
	-- its own file -- and THIS ONE DOES NOT: it is a record of things that
	-- happened, and nothing in the client can be asked for them again.
	--
	-- The count is in the question on purpose.  "Are you sure?" is a noise a
	-- player clicks through; "delete 412 rows" is a consequence.
	clear:SetScript ("OnClick", function ()
		if (StaticPopup_Show) then
			StaticPopup_Show ("ATR_LEDGER_CLEAR", #Ldg_Rows ());
		else
			Atr_Ledger_Clear ();			-- no popup machinery: behave as before
			Atr_Ledger_Redisplay ();
		end
	end);

	clear:SetScript ("OnEnter", function (self)
		if (GameTooltip) then
			GameTooltip:SetOwner (self, "ANCHOR_LEFT");
			GameTooltip:SetText (LZT("Clear the ledger"), 1, 1, 1);
			GameTooltip:AddLine (LZT("Deletes every recorded buy, sale and posting. This is the one thing here that scanning cannot grow back -- it is a record of what happened, not a cache. You will be asked to confirm."), 0.8, 0.8, 0.8, true);
			GameTooltip:Show();
		end
	end);
	clear:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);
end

if (StaticPopupDialogs) then

	-- %d is filled by StaticPopup_Show's first argument, above.
	StaticPopupDialogs["ATR_LEDGER_CLEAR"] = {
		text		= LZT("Delete all %d ledger rows?\n\nThis is your record of what you actually bought and sold. Scanning cannot bring it back."),
		button1		= YES,
		button2		= NO,
		OnAccept	= function ()
			Atr_Ledger_Clear ();
			Atr_Ledger_Redisplay ();
		end,
		timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1,
		showAlert = 1,			-- the yellow (!) -- this one deletes something
	};
end
