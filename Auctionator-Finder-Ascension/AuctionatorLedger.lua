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
