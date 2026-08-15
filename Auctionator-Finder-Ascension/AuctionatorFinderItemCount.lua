-- FINDER: item quantity + storage locations on tooltips -----------------------
--
-- Adds a "Qty" line to item tooltips telling you how many of that item you own,
-- and -- when a modifier is held -- WHERE they are: which character (bags vs.
-- bank) and how many sit in the account-wide web-shop banks.  Kept in its own
-- file so the tooltip/pricing code in AuctionatorHints.lua does not grow another
-- feature; the only touch there is one guarded call.
--
-- Why a cache.  The client can only READ a container's contents while its window
-- is open: away from a bank, the bank slots read back nil.  So we cannot ask
-- "how many do I own" on the fly -- we have to REMEMBER what each container held
-- the last time we saw it, in an account-wide saved variable.
--
--   AUCTIONATOR_ITEM_LOCATIONS = {
--       chars = {
--           ["Realm-Charname"] = {
--               name=, realm=, class=, faction=, updated=,
--               bags = { [itemID]=count },   -- backpack (bags 0..NUM_BAG_SLOTS)
--               bank = { [itemID]=count },   -- character bank (-1 + bank bags)
--               personal = { ntabs=, totals={[id]=n}, tabs={[t]={[id]=n}} },  -- THIS char's personal bank
--           },
--       },
--       webbanks = {                          -- shared vaults, keyed by realm
--           ["Realm"] = {
--               realm = { updated=, ntabs=, totals={[id]=n}, tabs={[t]={[id]=n}} },  -- one realm bank for all chars
--           },
--       },
--   }
--
-- The web-shop "Personal Bank" and "Realm Bank" both render through the stock
-- guild-bank API (GetGuildBankItemInfo etc.), and when either is open EVERY tab
-- is readable at once -- no per-tab query needed.  They are told apart by tab 1's
-- name: a "Realm Bank" tab present => the realm bank, otherwise the personal
-- bank (tabs 2+ carry unreliable names, so only tab 1 is trusted).  The PERSONAL
-- bank is per character (stored on the character entry, like bags/bank); the
-- REALM bank is one vault shared by every character on the realm (stored once).
-- The genuine GUILD bank reports zero tabs through this API and is a separate,
-- opt-in follow-up -- see Atr_ItemCount_ProbeGuildBank, the diagnostic used to
-- map all of the above.

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

-- Visibility modes shared by both dropdowns, matching AUCTIONATOR_DE_DETAILS_TIPS:
--   1 = when SHIFT held, 2 = when CTRL held, 3 = when ALT held, 4 = never, 5 = always
local function ModeVisible (mode)
	if (mode == 5) then return true;  end
	if (mode == 4) then return false; end
	if (mode == 1) then return IsShiftKeyDown();   end
	if (mode == 2) then return IsControlKeyDown(); end
	if (mode == 3) then return IsAltKeyDown();     end
	return true;		-- unknown/unset -> visible, never hide silently
end

-----------------------------------------
-- Cache: keys, structure, migration

local gBankOpen      = false;		-- between BANKFRAME_OPENED and _CLOSED (character bank)
local gGuildBankOpen = false;		-- between GUILDBANKFRAME_OPENED and _CLOSED (web-shop bank)

local function CharKey ()
	local name  = UnitName ("player") or "?";
	local realm = GetRealmName () or "";
	return realm.."-"..name, name, realm;
end

-- Return the account-wide DB, upgrading a Phase-1 flat layout (characters stored
-- at the top level) into the nested { chars=, webbanks= } shape in place.
local function EnsureDB ()
	if (type (AUCTIONATOR_ITEM_LOCATIONS) ~= "table") then
		AUCTIONATOR_ITEM_LOCATIONS = {};
	end
	local db = AUCTIONATOR_ITEM_LOCATIONS;

	if (type (db.chars) ~= "table") then
		local chars = {};
		for k, v in pairs (db) do		-- lift any legacy top-level char entries
			if (k ~= "chars" and k ~= "webbanks"
			    and type (v) == "table" and (v.bags or v.bank)) then
				chars[k] = v;
			end
		end
		db.chars = chars;
		for k in pairs (chars) do db[k] = nil; end
	end

	if (type (db.webbanks) ~= "table") then db.webbanks = {}; end

	-- An earlier build stored the personal bank as a single shared vault per
	-- realm.  Each character actually has their OWN personal bank, so that data
	-- can't be attributed to a character -- drop it; it re-caches per character
	-- the next time each opens their personal bank.  The realm bank stays.
	for _, w in pairs (db.webbanks) do
		if (type (w) == "table") then w.personal = nil; end
	end

	return db;
end

local function EnsureChar ()
	local db = EnsureDB ();
	local key, name, realm = CharKey ();
	local e = db.chars[key];
	if (type (e) ~= "table") then e = {}; db.chars[key] = e; end
	e.name  = name;
	e.realm = realm;
	local _, class = UnitClass ("player");
	e.class   = class;
	e.faction = UnitFactionGroup ("player");
	if (type (e.bags) ~= "table") then e.bags = {}; end
	if (type (e.bank) ~= "table") then e.bank = {}; end
	return e;
end

local function EnsureWebBanks ()
	local db = EnsureDB ();
	local realm = GetRealmName () or "";
	local w = db.webbanks[realm];
	if (type (w) ~= "table") then w = {}; db.webbanks[realm] = w; end
	return w;
end

-----------------------------------------
-- Scanning: character bags + bank

-- The backpack: bag 0 plus the four (NUM_BAG_SLOTS) equipped bags.
local function BackpackBags ()
	local t = {};
	for b = 0, (NUM_BAG_SLOTS or 4) do t[#t+1] = b; end
	return t;
end

-- The character bank: the 28-slot base container (BANK_CONTAINER = -1) plus the
-- purchased bank bags (NUM_BANKBAGSLOTS of them, sitting just past the backpack).
local function BankBags ()
	local t = { -1 };		-- BANK_CONTAINER
	local first = (NUM_BAG_SLOTS or 4) + 1;
	local last  = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7);
	for b = first, last do t[#t+1] = b; end
	return t;
end

-- Walk a list of container ids, returning a fresh { [itemID] = count } map.
local function ScanContainers (bagList)
	local counts = {};
	for _, bag in ipairs (bagList) do
		local slots = (GetContainerNumSlots and GetContainerNumSlots (bag)) or 0;
		for slot = 1, slots do
			local link = GetContainerItemLink (bag, slot);
			if (link) then
				local id = zc and zc.ItemIDfromLink (link);
				id = tonumber (id);
				if (id) then
					local _, cnt = GetContainerItemInfo (bag, slot);
					counts[id] = (counts[id] or 0) + (tonumber (cnt) or 1);
				end
			end
		end
	end
	return counts;
end

function Atr_ItemCount_ScanBags ()
	local e = EnsureChar ();
	e.bags    = ScanContainers (BackpackBags ());
	e.updated = time ();
end

function Atr_ItemCount_ScanBank ()
	if (not gBankOpen) then return; end		-- bank slots read nil when the window is shut
	local e = EnsureChar ();
	e.bank    = ScanContainers (BankBags ());
	e.updated = time ();
end

-----------------------------------------
-- Scanning: web-shop personal / realm banks (guild-bank API)

-- Which web-shop bank, if any, is open?  Decided by tab 1's name: a "Realm Bank"
-- tab present means the realm bank (its later tabs are misnamed "Personal Bank"
-- but hold realm storage), otherwise a "Personal Bank" tab means the personal
-- bank.  Zero tabs, or any other naming (the genuine guild bank), returns nil.
local function ClassifyOpenBank ()
	local n = (GetNumGuildBankTabs and GetNumGuildBankTabs ()) or 0;
	if (n <= 0) then return nil, 0; end

	local hasRealm, hasPersonal = false, false;
	for i = 1, n do
		local nm = GetGuildBankTabInfo (i) or "";
		if (nm:find ("Realm"))    then hasRealm    = true; end
		if (nm:find ("Personal")) then hasPersonal = true; end
	end

	if (hasRealm)    then return "realm",    n; end
	if (hasPersonal) then return "personal", n; end
	return nil, n;		-- real guild bank / unknown -> left alone
end

-- Read a single tab into a { [itemID]=count } map.  Returns the map and whether
-- ANY item was seen -- an all-empty read means the tab either is genuinely empty
-- OR (on a fresh bank open) has not streamed in from the server yet, and the two
-- are indistinguishable through this API.
local function ScanGuildTab (t)
	local slots = MAX_GUILDBANK_SLOTS_PER_TAB or 98;		-- stock tab is 14x7
	local tc, any = {}, false;
	for s = 1, slots do
		local link = GetGuildBankItemLink (t, s);
		if (link) then
			local id = zc and zc.ItemIDfromLink (link);
			id = tonumber (id);
			if (id) then
				local _, cnt = GetGuildBankItemInfo (t, s);
				tc[id] = (tc[id] or 0) + (tonumber (cnt) or 1);
				any = true;
			end
		end
	end
	return tc, any;
end

function Atr_ItemCount_ScanWebBank ()
	if (not gGuildBankOpen) then return; end

	local bankType, n = ClassifyOpenBank ();
	if (not bankType) then return; end

	-- MERGE into the existing record rather than replacing it.  When a bank first
	-- opens, only the tab in view has streamed in; the others read empty until
	-- clicked.  A full replace would wipe the counts we already cached for those
	-- tabs (the item vanishes from the tooltip, then returns when you open its
	-- tab).  So we refresh only tabs that actually have content this pass and keep
	-- the previously-cached contents of tabs that read empty (not yet loaded).
	local existing;
	if (bankType == "personal") then existing = EnsureChar ().personal;
	else                             existing = EnsureWebBanks ().realm; end
	local tabs = (existing and type (existing.tabs) == "table") and existing.tabs or {};

	for t = 1, n do
		local tc, any = ScanGuildTab (t);
		if (any) then
			tabs[t] = tc;					-- a loaded tab -> refresh it
		elseif (tabs[t] == nil) then
			tabs[t] = {};					-- first sight, empty/unloaded -> placeholder
		end									-- else: keep the prior (unloaded this pass)
	end

	-- Recompute the totals from the merged per-tab maps.
	local totals = {};
	for _, tc in pairs (tabs) do
		for id, c in pairs (tc) do totals[id] = (totals[id] or 0) + c; end
	end

	local ntabs = n;
	if (existing and (existing.ntabs or 0) > ntabs) then ntabs = existing.ntabs; end
	local rec = { updated = time (), ntabs = ntabs, totals = totals, tabs = tabs };
	if (bankType == "personal") then
		-- Each character has their OWN personal bank, so it belongs to whoever is
		-- looking at it -- stored on the character entry, like their bags/bank.
		EnsureChar ().personal = rec;
	else
		-- The realm bank is a single vault shared by all the account's characters
		-- on this realm, so it is stored once, per realm.
		EnsureWebBanks ().realm = rec;
	end
end

-----------------------------------------
-- Query + rendering

-- The tab indices of a web-bank record that hold the item, e.g. {1, 3}.
local function TabHits (rec, itemID)
	local hits = {};
	if (rec and type (rec.tabs) == "table") then
		for t = 1, (rec.ntabs or 0) do
			local tc = rec.tabs[t];
			if (tc and tc[itemID] and tc[itemID] > 0) then hits[#hits+1] = t; end
		end
	end
	return hits;
end

-- Total the item everywhere it is cached.  Returns:
--   total     grand total across characters (bags/bank/personal) + the realm bank
--   charList  { {name,class,bags,bank,personal,personalTabs,isCurrent}, ... }
--             current-character first -- personal bank is per character
--   webList   { {kind="realm", label, count, tabs={idx,...}} }  -- shared banks
function Atr_ItemCount_Query (itemID)
	itemID = tonumber (itemID);
	if (not itemID) then return 0, {}, {}; end

	local db     = EnsureDB ();
	local curKey = CharKey ();
	local total  = 0;
	local charList, webList = {}, {};

	for key, e in pairs (db.chars) do
		if (type (e) == "table") then
			local b = (type (e.bags) == "table" and e.bags[itemID]) or 0;
			local k = (type (e.bank) == "table" and e.bank[itemID]) or 0;
			local p = (type (e.personal) == "table" and type (e.personal.totals) == "table"
			           and e.personal.totals[itemID]) or 0;
			if (b + k + p > 0) then
				total = total + b + k + p;
				charList[#charList+1] = {
					name = e.name or key, realm = e.realm, class = e.class,
					bags = b, bank = k, personal = p,
					personalTabs = (p > 0) and TabHits (e.personal, itemID) or {},
					isCurrent = (key == curKey),
				};
			end
		end
	end

	table.sort (charList, function (a, c)
		if (a.isCurrent ~= c.isCurrent) then return a.isCurrent; end
		local at = a.bags + a.bank + a.personal;
		local ct = c.bags + c.bank + c.personal;
		if (at ~= ct) then return at > ct; end
		return (a.name or "") < (c.name or "");
	end);

	-- The shared realm bank for this realm.
	local realm = GetRealmName () or "";
	local w = db.webbanks[realm];
	local rb = (type (w) == "table") and w.realm or nil;
	local n = rb and type (rb.totals) == "table" and rb.totals[itemID];
	if (n and n > 0) then
		total = total + n;
		webList[#webList+1] = { kind = "realm", label = ZT ("Realm Bank"), count = n, tabs = TabHits (rb, itemID) };
	end

	return total, charList, webList;
end

-- Class-coloured character name for the location lines.
local function ColorName (c)
	local name = c.name or "?";
	if (c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]) then
		local col = RAID_CLASS_COLORS[c.class];
		return string.format ("|cff%02x%02x%02x%s|r",
			(col.r or 1) * 255, (col.g or 1) * 255, (col.b or 1) * 255, name);
	end
	return "|cFFFFFFFF"..name.."|r";
end

-- Public entry point, called once from ShowTipWithPricing.  Adds nothing unless
-- the quantity mode is visible and the item is actually held somewhere.
function Atr_ItemCount_AddToTip (tip, itemID)
	if (tip == nil or itemID == nil) then return; end
	if (not ModeVisible (AUCTIONATOR_QTY_TIPS or 5)) then return; end

	local total, charList, webList = Atr_ItemCount_Query (itemID);
	if (total <= 0) then return; end

	tip:AddDoubleLine (ZT ("Qty"), "|cFFFFFFFF"..total.."|r");

	local locMode = AUCTIONATOR_QTY_LOC_TIPS or 3;
	if (ModeVisible (locMode)) then
		-- Per character: bags, bank, and THIS character's own personal bank.
		for _, c in ipairs (charList) do
			local parts = {};
			if (c.bags and c.bags > 0) then parts[#parts+1] = c.bags.." "..ZT ("bags"); end
			if (c.bank and c.bank > 0) then parts[#parts+1] = c.bank.." "..ZT ("bank"); end
			if (c.personal and c.personal > 0) then
				local seg = c.personal.." "..ZT ("Personal Bank");
				if (#c.personalTabs > 0) then
					seg = seg.." |cFF888888("..ZT ("tab")..(#c.personalTabs > 1 and "s" or "").." "
					      ..table.concat (c.personalTabs, ", ")..")|r";
				end
				parts[#parts+1] = seg;
			end
			tip:AddDoubleLine ("  "..ColorName (c), "|cFFCCCCCC"..table.concat (parts, ", ").."|r");
		end
		-- Shared banks (the realm bank), not tied to any one character.
		for _, b in ipairs (webList) do
			local label = "  |cFFFFD100"..b.label.."|r";
			if (#b.tabs > 0) then
				label = label.." |cFF888888("..ZT ("tab")..(#b.tabs > 1 and "s" or "").." "
				        ..table.concat (b.tabs, ", ")..")|r";
			end
			tip:AddDoubleLine (label, "|cFFCCCCCC"..b.count.."|r");
		end
	elseif (locMode == 1 or locMode == 2 or locMode == 3) then
		-- Faint breadcrumb so the hidden locations are discoverable.
		local keyName = (locMode == 1 and "SHIFT") or (locMode == 2 and "CTRL") or "ALT";
		tip:AddLine ("|cFF808080"..string.format (ZT ("Hold <%s> for locations"), keyName).."|r");
	end

	tip:Show ();
end

-----------------------------------------
-- Diagnostics
--
-- Map the guild-bank-family surface for a bank you have open:
--   /run Atr_ItemCount_ProbeGuildBank()

function Atr_ItemCount_ProbeGuildBank ()
	local out = DEFAULT_CHAT_FRAME;
	local function p (s) if (out) then out:AddMessage ("|cff44ddffAtrItemCount|r "..tostring (s)); end end

	p ("--- guild-bank-family probe ---");
	p ("IsInGuild = "..tostring (IsInGuild and IsInGuild ()));
	p ("GetGuildInfo(player) = "..tostring (GetGuildInfo and GetGuildInfo ("player")));

	local nTabs = GetNumGuildBankTabs and GetNumGuildBankTabs () or 0;
	p ("GetNumGuildBankTabs = "..tostring (nTabs));
	p ("classified as = "..tostring ((ClassifyOpenBank ())));

	for t = 1, nTabs do
		local name, icon = GetGuildBankTabInfo (t);
		p (string.format ("  tab %d: name=%s icon=%s", t, tostring (name), tostring (icon)));
	end
end

-- Sanity dump of what the cache currently holds:  /run Atr_ItemCount_Dump()
function Atr_ItemCount_Dump ()
	local out = DEFAULT_CHAT_FRAME;
	local function p (s) if (out) then out:AddMessage ("|cff44ddffAtrItemCount|r "..tostring (s)); end end
	local db = EnsureDB ();

	local nChars = 0;
	for key, e in pairs (db.chars) do
		nChars = nChars + 1;
		local nb, nk, np = 0, 0, 0;
		for _ in pairs (e.bags or {}) do nb = nb + 1; end
		for _ in pairs (e.bank or {}) do nk = nk + 1; end
		if (type (e.personal) == "table") then for _ in pairs (e.personal.totals or {}) do np = np + 1; end end
		p (string.format ("%s: %d bag-stacks, %d bank-stacks, %d personal-bank-stacks", key, nb, nk, np));
	end
	for realm, w in pairs (db.webbanks) do
		if (type (w.realm) == "table") then
			local ni = 0;
			for _ in pairs (w.realm.totals or {}) do ni = ni + 1; end
			p (string.format ("realm bank %s: %d items across %d tabs", realm, ni, w.realm.ntabs or 0));
		end
	end
	p ("cached characters: "..nChars.."   bankOpen="..tostring (gBankOpen)
	   .."   guildBankOpen="..tostring (gGuildBankOpen));
end

-----------------------------------------
-- Event wiring: keep the cache fresh

if (type (CreateFrame) == "function") then

	local f = CreateFrame ("Frame", "Atr_Finder_ItemCountScan", UIParent);

	f:RegisterEvent ("PLAYER_LOGIN");
	f:RegisterEvent ("PLAYER_ENTERING_WORLD");
	f:RegisterEvent ("BAG_UPDATE");
	f:RegisterEvent ("BANKFRAME_OPENED");
	f:RegisterEvent ("BANKFRAME_CLOSED");
	f:RegisterEvent ("PLAYERBANKSLOTS_CHANGED");
	f:RegisterEvent ("PLAYERBANKBAGSLOTS_CHANGED");
	f:RegisterEvent ("GUILDBANKFRAME_OPENED");
	f:RegisterEvent ("GUILDBANKFRAME_CLOSED");
	f:RegisterEvent ("GUILDBANKBAGSLOTS_CHANGED");
	f:RegisterEvent ("GUILDBANK_UPDATE_TABS");

	local DELAY   = 0.4;		-- debounce the update storms
	local elapsed = 0;
	local bagsDirty, bankDirty, webDirty = false, false, false;

	f:Hide ();				-- OnUpdate only ticks while shown; idle until armed

	f:SetScript ("OnEvent", function (self, event)
		if (event == "BANKFRAME_OPENED") then
			gBankOpen = true; bankDirty = true; bagsDirty = true;
		elseif (event == "BANKFRAME_CLOSED") then
			gBankOpen = false;		-- last good snapshot stays in the saved var
		elseif (event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED") then
			if (gBankOpen) then bankDirty = true; end
		elseif (event == "GUILDBANKFRAME_OPENED") then
			gGuildBankOpen = true; webDirty = true;
		elseif (event == "GUILDBANKFRAME_CLOSED") then
			gGuildBankOpen = false;
		elseif (event == "GUILDBANKBAGSLOTS_CHANGED" or event == "GUILDBANK_UPDATE_TABS") then
			if (gGuildBankOpen) then webDirty = true; end
		elseif (event == "BAG_UPDATE") then
			bagsDirty = true;
			if (gBankOpen) then bankDirty = true; end		-- bank bags report through BAG_UPDATE too
		else		-- PLAYER_LOGIN / PLAYER_ENTERING_WORLD
			bagsDirty = true;
		end
		elapsed = 0;
		self:Show ();
	end);

	f:SetScript ("OnUpdate", function (self, dt)
		elapsed = elapsed + (dt or 0);
		if (elapsed >= DELAY) then
			elapsed = 0;
			self:Hide ();		-- one-shot: stop ticking before scanning
			if (bagsDirty) then bagsDirty = false; pcall (Atr_ItemCount_ScanBags);    end
			if (bankDirty) then bankDirty = false; pcall (Atr_ItemCount_ScanBank);    end
			if (webDirty)  then webDirty  = false; pcall (Atr_ItemCount_ScanWebBank); end
		end
	end);
end
