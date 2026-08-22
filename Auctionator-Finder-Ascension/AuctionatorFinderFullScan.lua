-------------------------------------------------------------------------------
-- AuctionatorFinderFullScan.lua
--
-- The Finder's replacement for upstream's dead getAll "Full Scan": a
-- sequential, per-category paged sweep driven from the Scan Categories button.
--
-- Split out of AuctionatorFinder.lua (was the "full scan replacement" section).
-- Self-contained: it only exports its own globals and reads shared helpers
-- (FT localization, zc messaging) the same way every Auctionator file does.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;
local F  = addonTable and addonTable.Finder;
local FT = F and F.FT;

-- ===========================================================================
-- FINDER_TAB begin: full scan replacement
--
-- Upstream's Full Scan is dead on this server, twice over:
--   * Atr_FullScanStart calls QueryAuctionItems(..., getAll=true), which
--     Ascension disables; and
--   * Atr_UpdateFullScanFrame DISABLES the Start button whenever
--     CanSendAuctionQuery's second return is false, which here it always is.
-- So the button is greyed out before it can even fail.  Upstream's paged
-- alternative was abandoned mid-wiring (Atr_FullScan_Slow is commented out
-- in Auctionator.xml, and Atr_FullScanStart reads a local that is always
-- false).
--
-- This replaces all three entry points -- Atr_ShowFullScanFrame,
-- Atr_UpdateFullScanFrame and Atr_FullScanStart -- by REDEFINING the
-- globals.  The toc loads AuctionatorFinder.lua after AuctionatorScan.lua,
-- so the later definition wins and neither AuctionatorScan.lua nor
-- Auctionator.xml needs editing.
--
-- The dialog is reused rather than replaced: Atr_FullScanFrame already has
-- the item-count readout, the last-scan line, a status line and a Done
-- button.  Only Atr_FullScanHTML (the explanation blob, 405x300 at 27,-175)
-- is hidden, and the category picker is built in Lua in that space (a little
-- wider now: the dialog grew to 520 to fit the gear rows' level range).
--
-- GEAR IS IN, AS OF 2026-08-22, AND THE OLD REASONING IS WORTH KEEPING.
--
-- SUPERSEDED: the Weapon and Armor rows used to be present-but-disabled, on the
-- grounds that gAtr_ScanDB is keyed by item NAME -- on Ascension one name covers
-- many scaled instances at different item levels, so a single stored price would
-- stand in for every variant and be wrong for all but one.  Rule 2 of the price
-- feed refuses scaled equipment, so a gear sweep burned an enormous amount of
-- scan time to store almost nothing.  All of that is still true of the NAME-keyed
-- database, and rule 2 is untouched.
--
-- What changed is that gear no longer has to be stored by name.  Two things were
-- built after that decision:
--
--   * AUCTIONATOR_AH_VARIANT, keyed (itemID, ilvl, req) -- the tuple that names
--     a scale-variant exactly.  It was fed only by the Verify sweep.
--   * Fdr_HarvestListIlvl, which reads a listing's server tooltip WHILE ITS PAGE
--     IS STILL CURRENT.  That is the only cheap moment a scaled listing's true
--     item level exists, and it is exactly the moment a category sweep is in.
--
-- So a gear sweep now files every scaled listing it sees under its own variant
-- key, and the tooltip on the item in your bags reads the price back from the
-- same tuple.  The name-keyed DB still gets the UNSCALED gear (rule 2 skips the
-- rest), which is correct and was always safe.
--
-- IT IS STILL THE LONGEST SWEEP THERE IS, which is why the two gear rows are the
-- only ones that start UNTICKED and the only ones that carry a level range: the
-- server filters on required level, and on this realm that is the very axis the
-- scale-variants differ along.  "Armor 70-80" is both a short scan and a
-- meaningful slice; "Armor, everything" is neither.  Every other category is
-- scanned whole, so those rows are a checkbox and nothing else.
--
-- MEMORY: categories run ONE AT A TIME and the price feed flushes after
-- each.  A single Trade Goods sweep on this realm is ~37k records; holding
-- Consumables, Recipes, Glyphs and Gems simultaneously would be far worse.
-- Sequential also means a cancel keeps everything already priced.
-- ===========================================================================

local FS_WEAPON_CLASS	= 1;		-- GetAuctionItemClasses indices, stable in 3.3.5
local FS_ARMOR_CLASS	= 2;

-- Ammunition and quivers are two tiny classes that nobody thinks of as
-- separate shopping trips, so they are folded into Miscellaneous: one
-- checkbox, three server scans.  Keyed by CLASS NAME rather than index
-- because Ascension's class list is not stock (it appends "Quest"), and a
-- name lookup degrades to "no merge" instead of merging the wrong thing.
local FS_MERGE_INTO = {
	["Projectile"]	= "Miscellaneous",
	["Quiver"]		= "Miscellaneous",
};

local gFS_Queue		= nil;		-- selected classes for the run in progress
local gFS_Index		= 0;
local gFS_Added		= 0;
local gFS_Updated	= 0;
local gFS_Skipped	= 0;
local gFS_Variants	= 0;		-- scale-variant gear prices filed by this run
local gFS_Bazaar	= false;
local gFS_Built		= false;
local gFS_Cancelling = false;	-- re-entrancy guard: the cancel path is mutual



-- Gear is no longer refused; it is merely EXPENSIVE.  This predicate now says
-- three things, all of them "treat this class as the big one": start unticked,
-- read each listing's server tooltip during the sweep (spec.harvestTrue), and
-- say so in the picker.
function Fdr_FS_IsGearClass (ci)
	return (ci == FS_WEAPON_CLASS or ci == FS_ARMOR_CLASS);
end


-- Every auction class.  The gear flag no longer means "refused" -- it means
-- "long, and off unless you ask for it"; the picker labels those two rows
-- rather than greying them.
function Fdr_FS_Classes ()

	local names;
	if (Atr_GetAuctionClasses) then
		names = Atr_GetAuctionClasses ();
	elseif (GetAuctionItemClasses) then
		names = { GetAuctionItemClasses () };
	else
		names = {};
	end

	-- index the merge targets first, so a member can be attached to its host
	-- wherever the two happen to sit in the list
	local hostOf, byName = {}, {};
	local i;
	for i = 1, #names do byName[names[i]] = i; end
	for i = 1, #names do
		local into = FS_MERGE_INTO[names[i]];
		if (into and byName[into]) then hostOf[i] = byName[into]; end
	end

	local out, slot = {}, {};
	for i = 1, #names do
		if (hostOf[i] == nil) then
			out[#out + 1] = { ci = i, name = names[i], gear = Fdr_FS_IsGearClass (i),
							  members = { i } };
			slot[i] = out[#out];
		end
	end

	-- attach each merged class to its host's member list
	for i = 1, #names do
		local host = hostOf[i];
		if (host and slot[host]) then
			tinsert (slot[host].members, i);
		end
	end

	return out;
end


function Fdr_FS_Store ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then AUCTIONATOR_FINDER_SETTINGS = {}; end
	if (type (AUCTIONATOR_FINDER_SETTINGS.fullScanCats) ~= "table") then
		AUCTIONATOR_FINDER_SETTINGS.fullScanCats = {};
	end
	return AUCTIONATOR_FINDER_SETTINGS.fullScanCats;
end


-- Default ON for everything except the two gear classes: those are the longest
-- sweeps on the auction house and nobody should get one by pressing a button
-- they have not looked at.  An explicit false is still false, so a stored
-- choice always wins over the default.
function Fdr_FS_IsSelected (ci)

	local v = Fdr_FS_Store()[tostring (ci)];
	if (v == nil) then return not Fdr_FS_IsGearClass (ci); end
	return v and true or false;
end


function Fdr_FS_SetSelected (ci, on)

	Fdr_FS_Store()[tostring (ci)] = on and true or false;
	return true;
end


-- ---------------------------------------------------------------------------
-- per-category level range (blank = the whole class)
-- ---------------------------------------------------------------------------
--
-- AUCTIONATOR_FINDER_SETTINGS.fullScanLevels[tostring(ci)] = { min = n, max = n }
--
-- Stored under the CHECKBOX's class index and applied to every class that
-- checkbox scans, so the merged Miscellaneous row's range covers Projectile and
-- Quiver too -- one visible control, one meaning.
--
-- Absent or 0 means "no bound on that end", which is what QueryAuctionItems
-- itself wants: it takes nil for an open end and treats 0 as a real level.
function Fdr_FS_LevelStore ()

	if (AUCTIONATOR_FINDER_SETTINGS == nil) then AUCTIONATOR_FINDER_SETTINGS = {}; end
	if (type (AUCTIONATOR_FINDER_SETTINGS.fullScanLevels) ~= "table") then
		AUCTIONATOR_FINDER_SETTINGS.fullScanLevels = {};
	end
	return AUCTIONATOR_FINDER_SETTINGS.fullScanLevels;
end


-- Returns min, max -- either or both nil.  A range typed backwards (80-70) is
-- returned the right way round rather than refused: the server answers a
-- backwards range with nothing at all, which reads in game as "the scan is
-- broken" and is a miserable thing to debug from a status line.
--
-- ONLY THE TWO GEAR CLASSES HAVE A RANGE.  The picker used to put a pair of
-- boxes on every row; it now puts them on Weapons and Armor only, because
-- required level is the axis the SCALED versions of one item differ along and
-- that is a gear-shaped idea -- on Trade Goods or Recipes the pair was a
-- control with nothing behind it.  A stored range for any other class (an
-- older settings file, or a hand-edited one) is therefore ignored rather than
-- silently narrowing a scan whose picker row shows no such thing.
function Fdr_FS_Levels (ci)

	if (not Fdr_FS_IsGearClass (ci)) then return nil, nil; end

	local e = Fdr_FS_LevelStore()[tostring (ci)];
	if (type (e) ~= "table") then return nil, nil; end

	local lo = tonumber (e.min or 0) or 0;
	local hi = tonumber (e.max or 0) or 0;

	if (lo <= 0) then lo = nil; end
	if (hi <= 0) then hi = nil; end

	if (lo and hi and lo > hi) then return hi, lo; end

	return lo, hi;
end


function Fdr_FS_SetLevels (ci, lo, hi)

	lo = tonumber (lo or 0) or 0;
	hi = tonumber (hi or 0) or 0;

	local store = Fdr_FS_LevelStore ();

	if (lo <= 0 and hi <= 0) then
		store[tostring (ci)] = nil;			-- blank is the default, so store nothing
		return true;
	end

	store[tostring (ci)] = { min = (lo > 0) and lo or nil,
							 max = (hi > 0) and hi or nil };
	return true;
end


-- "60-70", "60+", "up to 70", or nil when the whole class is being scanned.
-- Used in the queue label, so a run's status line says which slice it is on.
function Fdr_FS_LevelText (lo, hi)

	if (lo and hi) then return lo.."-"..hi; end
	if (lo) then return lo.."+"; end
	if (hi) then return FT("up to ")..hi; end
	return nil;
end


-- One entry per SERVER SCAN, not per checkbox: ticking Miscellaneous yields
-- Miscellaneous, Projectile and Quiver.  Everything downstream -- the queue,
-- the "n of m" counter and the readout on the dialog -- then counts the same
-- thing, so none of them can disagree.
function Fdr_FS_SelectedClasses ()

	local all, out = Fdr_FS_Classes (), {};
	local names = (Atr_GetAuctionClasses and Atr_GetAuctionClasses ()) or {};

	local i, j;
	for i = 1, #all do
		if (Fdr_FS_IsSelected (all[i].ci)) then

			local lo, hi = Fdr_FS_Levels (all[i].ci);
			local m = all[i].members or { all[i].ci };

			for j = 1, #m do
				out[#out + 1] = { ci		= m[j],
								  name		= names[m[j]] or all[i].name,
								  minLevel	= lo,
								  maxLevel	= hi,
								  -- the tooltip read is per LISTING and only pays
								  -- for itself where the listings are gear
								  harvest	= Fdr_FS_IsGearClass (m[j]) };
			end
		end
	end
	return out;
end


function Fdr_FS_Running ()
	return gFS_Queue ~= nil;
end


function Fdr_FS_Status (s)
	if (Atr_FullScanStatus) then Atr_FullScanStatus:SetText (s or ""); end
end


-- Echo of the engine's own status line, prefixed with our position in the
-- queue.  The engine's text already names the category and carries
-- "page N / M", so this composes rather than duplicating.
function Fdr_FS_EchoProgress (msg)

	if (gFS_Queue == nil) then return; end
	if (type (msg) ~= "string" or msg == "") then return; end

	Fdr_FS_Status (string.format ("(%d/%d)  %s", gFS_Index, #gFS_Queue, msg));
end


function Fdr_FS_UpdateButtons ()

	if (Atr_FullScanStartButton) then
		Atr_FullScanStartButton:Enable();		-- never gated on canQueryAll: we do not use getAll
		Atr_FullScanStartButton:SetText (Fdr_FS_Running() and FT("Cancel") or FT("Scan Categories"));
	end

	if (Atr_FullScanDone) then
		if (Fdr_FS_Running()) then Atr_FullScanDone:Disable(); else Atr_FullScanDone:Enable(); end
	end
end


-- Atr_Finder_CancelSearch calls back into here, so the two guard each other
-- with gFS_Cancelling rather than one of them being careful about ordering.
-- Stopping the queue is NOT enough on its own: the Finder engine owns an
-- in-flight category scan and would keep paging (and then hold the engine so
-- the next run could not start at all).
function Fdr_FS_Cancel (quiet)

	if (gFS_Cancelling) then return; end
	gFS_Cancelling = true;

	local was = gFS_Queue;

	gFS_Queue = nil;
	gFS_Index = 0;

	Atr_Finder_SetFinishHook (nil);

	if (Atr_Finder_CancelSearch) then
		local a, u = Atr_Finder_CancelSearch (false);
		gFS_Added	= gFS_Added + (a or 0);		-- bank the partial flush
		gFS_Updated	= gFS_Updated + (u or 0);

		-- and the gear prices that flush filed.  Read AFTER the cancel, which is
		-- what recorded them; the two calls are mutually guarded by
		-- gFS_Cancelling, so this cannot count the same rows twice.
		if (Atr_Finder_VariantsStored) then
			gFS_Variants = gFS_Variants + Atr_Finder_VariantsStored ();
		end
	end
	if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end

	gFS_Cancelling = false;

	if (was and not quiet) then
		local stopped = string.format (FT("Stopped - %d new, %d updated"), gFS_Added, gFS_Updated);
		if (gFS_Variants > 0) then
			stopped = stopped..string.format (FT(", %d gear prices by version"), gFS_Variants);
		end
		Fdr_FS_Status (stopped);
	end

	Fdr_FS_UpdateButtons ();
	if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
end


-- Optional tail phase: price the Bazaar catalogue too.  Handed off to the
-- Bazaar's own sequential scanner, which already records per-item buyouts.
function Fdr_FS_StartBazaar ()

	if (not (gFS_Bazaar and Atr_Bz_StartCategoryScan)) then return false; end

	Fdr_FS_Status (FT("Pricing the Bazaar catalogue..."));
	return Atr_Bz_StartCategoryScan () and true or false;
end


function Fdr_FS_Done ()

	local n = gFS_Index - 1;

	gFS_Queue = nil;
	gFS_Index = 0;

	Atr_Finder_SetFinishHook (nil);

	Fdr_FS_StartBazaar ();

	local done = string.format (FT("Done: %d %s, %d new, %d updated"),
					n, (n == 1) and FT("category") or FT("categories"),
					gFS_Added, gFS_Updated);

	-- The gear half of the run is invisible in the two counters above: those
	-- are the name-keyed database, which refuses scaled gear by design, so a
	-- Weapons-and-Armor run would otherwise report "0 new, 0 updated" having
	-- filed several thousand prices.
	if (gFS_Variants > 0) then
		done = done..string.format (FT(", %d gear prices by version"), gFS_Variants);
	end

	Fdr_FS_Status (done);

	Fdr_FS_UpdateButtons ();
	if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
end


function Fdr_FS_Next ()

	if (gFS_Queue == nil) then return; end

	gFS_Index = gFS_Index + 1;

	local entry = gFS_Queue[gFS_Index];
	if (entry == nil) then
		Fdr_FS_Done ();
		return;
	end

	local label = entry.name or "?";
	local range = Fdr_FS_LevelText (entry.minLevel, entry.maxLevel);
	if (range) then label = label.." ("..range..")"; end

	Fdr_FS_Status (string.format (FT("Scanning %s (%d of %d)"),
					label, gFS_Index, #gFS_Queue));

	-- minLevel/maxLevel are read by Fdr_SendQuery in place of the Finder tab's
	-- own boxes; harvestTrue turns on the per-listing tooltip read in
	-- Fdr_HarvestPage.  Both are inert on a spec that does not set them, so
	-- nothing else that builds a spec queue is affected.
	local spec = { class = entry.ci, subclass = nil, autoAccept = true, label = label,
				   minLevel = entry.minLevel, maxLevel = entry.maxLevel,
				   harvestTrue = entry.harvest };

	local started = Atr_Finder_StartQueueScan ({ spec }, function (added, updated, skipped)
			gFS_Added	= gFS_Added + (added or 0);
			gFS_Updated	= gFS_Updated + (updated or 0);
			gFS_Skipped	= gFS_Skipped + (skipped or 0);
			if (Atr_Finder_VariantsStored) then
				gFS_Variants = gFS_Variants + Atr_Finder_VariantsStored ();
			end
			if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
			Fdr_FS_Next ();
		end);

	if (not started) then
		-- something else owns the engine; stop rather than spin
		Fdr_FS_Cancel (true);
		Fdr_FS_Status (FT("Finish or cancel the scan first"));
		Fdr_FS_UpdateButtons ();
	end
end


-- ---------------------------------------------------------------------------
-- the picker, built into the space Atr_FullScanHTML used to occupy
-- ---------------------------------------------------------------------------

-- Column geometry.  Two columns of rows, each row: checkbox + label on the
-- left, and on the two GEAR rows a min/max pair on the right at a FIXED x so
-- the boxes line up down the column however long the labels are.  The dialog
-- was widened to 520 to pay for the pair (Auctionator.xml); at 405 the boxes
-- sat on top of "Miscellaneous".  The width stays: the pair is rarer now, not
-- gone, and it still needs the room.
local FS_COL_W		= 232;		-- distance between the two columns
local FS_ROW_H		= 22;
local FS_LVL_X		= 132;		-- min box, relative to its column
local FS_LVL_DASH	= 167;
local FS_LVL_X2		= 177;		-- max box
local FS_LVL_W		= 30;

-- One min/max pair, built for the gear rows only (see the call site).  Both
-- boxes write straight through to Fdr_FS_SetLevels on every keystroke rather
-- than on focus loss: pressing Start Scanning is a click elsewhere, and a box
-- that only commits on OnEditFocusLost has a real chance of being read one
-- keystroke stale by the very button the user pressed next.
local function Fdr_FS_MakeLevelBox (panel, e, x, y, which)

	local box = CreateFrame ("EditBox", "Atr_FS_Lvl"..which..e.ci, panel, "InputBoxTemplate");
	box:SetSize (FS_LVL_W, 18);
	box:SetPoint ("TOPLEFT", x, y);
	box:SetAutoFocus (false);
	box:SetNumeric (true);
	box:SetMaxLetters (3);
	box:SetJustifyH ("CENTER");

	local lo, hi = Fdr_FS_Levels (e.ci);
	local cur = (which == "Min") and lo or hi;
	box:SetText (cur and tostring (cur) or "");

	box:SetScript ("OnTextChanged", function (self)
			-- read BOTH boxes and write the pair: the store keeps a range, not
			-- two independent numbers, and a half-written pair is a range
			-- somebody has to guess the other end of
			local mn = _G["Atr_FS_LvlMin"..e.ci];
			local mx = _G["Atr_FS_LvlMax"..e.ci];
			Fdr_FS_SetLevels (e.ci,
					mn and mn:GetNumber() or 0,
					mx and mx:GetNumber() or 0);
		end);

	box:SetScript ("OnEnterPressed",  function (self) self:ClearFocus(); end);
	box:SetScript ("OnEscapePressed", function (self) self:ClearFocus(); end);

	if (GameTooltip) then
		box:SetScript ("OnEnter", function (self)
				GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
				GameTooltip:SetText (FT("Required level"), 1, 1, 1);
				GameTooltip:AddLine (FT("Only scan listings inside this required-level range. Leave both blank to scan the whole class. Required level is the axis the scaled versions of an item differ along, so a range both shortens the longest sweep there is and picks a real slice of the market."), nil, nil, nil, true);
				GameTooltip:Show();
			end);
		box:SetScript ("OnLeave", function () GameTooltip:Hide(); end);
	end

	return box;
end


function Fdr_FS_BuildPicker ()

	if (gFS_Built) then return true; end
	if (not (Atr_FullScanFrame and CreateFrame)) then return false; end

	local panel = CreateFrame ("Frame", "Atr_FS_Picker", Atr_FullScanFrame);
	panel:SetPoint ("TOPLEFT", 27, -175);
	panel:SetWidth (465);
	panel:SetHeight (270);

	local head = panel:CreateFontString ("Atr_FS_PickerHead", "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", 0, 0);
	head:SetText (FT("Categories to scan"));

	local all = Fdr_FS_Classes ();

	-- balance the two columns instead of hardcoding a wrap: the class list is
	-- not stock here (Ascension appends "Quest") and merging shortens it again
	local perCol = math.ceil (#all / 2);
	if (perCol < 1) then perCol = 1; end

	-- One "Levels" caption per column, over that column's boxes -- and only over
	-- a column that HAS boxes.  Only the two gear rows carry a pair now, so a
	-- caption over a column of bare checkboxes would be labelling nothing.
	local hasBoxes = {};
	for i = 1, #all do
		if (all[i].gear) then hasBoxes[math.floor ((i - 1) / perCol)] = true; end
	end

	local c;
	for c = 0, 1 do
		if (hasBoxes[c]) then
			local cap = panel:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
			cap:SetPoint ("TOPLEFT", c * FS_COL_W + FS_LVL_X, -2);
			cap:SetText ("|cff909090"..FT("Levels").."|r");
		end
	end

	local col, row = 0, 0;
	local i;

	for i = 1, #all do

		local e	  = all[i];
		local cb  = CreateFrame ("CheckButton", "Atr_FS_Cat"..e.ci, panel, "UICheckButtonTemplate");
		local txt = _G["Atr_FS_Cat"..e.ci.."Text"];

		local y = -22 - (row * FS_ROW_H);

		cb:SetSize (20, 20);
		cb:SetPoint ("TOPLEFT", col * FS_COL_W, y);

		-- a merged row says what it now covers, so the fold is not a surprise
		local label = e.name or ("#"..e.ci);
		if (e.members and #e.members > 1) then
			label = label.." |cff808080+|r";
		end

		if (txt) then txt:SetText (label); end

		cb:SetChecked (Fdr_FS_IsSelected (e.ci) and true or nil);
		cb:SetScript ("OnClick", function (self)
				Fdr_FS_SetSelected (e.ci, self:GetChecked() and true or false);
				if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
			end);

		-- what a row's tooltip says: the merged classes for a folded row, the
		-- cost warning for a gear one.  Neither is guessable from the label.
		local tip = nil;
		if (e.members and #e.members > 1) then
			local names = (Atr_GetAuctionClasses and Atr_GetAuctionClasses ()) or {};
			local parts, k = {}, nil;
			for k = 1, #e.members do parts[k] = names[e.members[k]] or "?"; end
			tip = FT("Scans: ")..table.concat (parts, ", ");
		end

		local note = nil;
		if (e.gear) then
			note = FT("The longest sweep on the auction house, so this one starts off. Each listing's server tooltip is read as the page arrives, which is what lets its price be filed under its own scaled version instead of being thrown away. Set a level range to keep it short.");
		end

		if ((tip or note) and GameTooltip) then
			cb:SetScript ("OnEnter", function (self)
					GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
					GameTooltip:SetText (tip or label, 1, 1, 1);
					if (note) then GameTooltip:AddLine (note, nil, nil, nil, true); end
					GameTooltip:Show();
				end);
			cb:SetScript ("OnLeave", function () GameTooltip:Hide(); end);
		end

		-- The range is a GEAR control, not a general one.  Required level is the
		-- axis the scaled versions of one item differ along, so on Weapons and
		-- Armor a range both shortens the longest sweep there is and picks a real
		-- slice of the market; on Trade Goods or Recipes it was a pair of boxes
		-- offering to narrow a scan nobody wanted narrowed.  Every other row is
		-- the checkbox alone (owner's request, 2026-08-22).
		if (e.gear) then

			Fdr_FS_MakeLevelBox (panel, e, col * FS_COL_W + FS_LVL_X, y - 1, "Min");

			local dash = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
			dash:SetPoint ("TOPLEFT", col * FS_COL_W + FS_LVL_DASH, y - 5);
			dash:SetText ("-");

			Fdr_FS_MakeLevelBox (panel, e, col * FS_COL_W + FS_LVL_X2, y - 1, "Max");
		end

		row = row + 1;
		if (row >= perCol) then row = 0; col = col + 1; end
	end

	local yBase = -22 - (perCol * FS_ROW_H) - 10;

	local bz = CreateFrame ("CheckButton", "Atr_FS_BazaarCheck", panel, "UICheckButtonTemplate");
	bz:SetSize (20, 20);
	bz:SetPoint ("TOPLEFT", 0, yBase);
	bz:SetChecked (nil);
	if (_G["Atr_FS_BazaarCheckText"]) then
		_G["Atr_FS_BazaarCheckText"]:SetText (FT("Also price the Bazaar catalogue"));
	end

	-- What the level boxes are for, and what a gear scan does with what it
	-- finds.  3.3.5 FontStrings wrap once a width is set and nothing clips them,
	-- so the width is fixed and the height is not.
	local why = panel:CreateFontString ("Atr_FS_PickerNote", "ARTWORK", "GameFontNormalSmall");
	why:SetPoint ("TOPLEFT", 0, yBase - 30);
	why:SetWidth (455);
	why:SetJustifyH ("LEFT");
	why:SetText ("|cffffcc00"..FT("Weapons and Armor take a required-level range; blank scans the whole class.").."|r  "
				..FT("Weapons and Armor start unticked because a whole-class sweep is the longest "
					.."scan there is - give them a range. Their prices are filed under each scaled "
					.."version of an item (item level and required level), not under its name, so a "
					.."tooltip shows the price of the version you are actually holding."));

	gFS_Built = true;
	return true;
end


-- The picker is built ONCE and reused (SELL-TAB-COST.md: a window that rebuilds
-- its widgets is a window that leaks them), so the widgets have to be put back
-- in step with the store on each show rather than at create time.  In practice
-- they only ever drift when something outside this file writes the settings --
-- a hand-edited SavedVariables, or a future options panel -- but a picker that
-- shows a range it will not scan is the worst kind of wrong.
function Fdr_FS_SyncPicker ()

	if (not gFS_Built) then return false; end

	local all = Fdr_FS_Classes ();
	local i;

	for i = 1, #all do

		local ci = all[i].ci;

		local cb = _G["Atr_FS_Cat"..ci];
		if (cb) then cb:SetChecked (Fdr_FS_IsSelected (ci) and true or nil); end

		-- only the gear rows have boxes to put back in step; the lookups are
		-- guarded anyway, so this stays correct if that ever changes again
		local lo, hi = Fdr_FS_Levels (ci);
		local mn = _G["Atr_FS_LvlMin"..ci];
		local mx = _G["Atr_FS_LvlMax"..ci];
		if (mn) then mn:SetText (lo and tostring (lo) or ""); end
		if (mx) then mx:SetText (hi and tostring (hi) or ""); end
	end

	return true;
end


-- ---------------------------------------------------------------------------
-- the three upstream globals, replaced
-- ---------------------------------------------------------------------------

function Atr_ShowFullScanFrame ()

	if (not Atr_FullScanFrame) then return; end

	if (Atr_FullScanHTML)	 then Atr_FullScanHTML:Hide();	  end	-- the explanation blob
	if (Atr_FullScanResults) then Atr_FullScanResults:Hide(); end

	Fdr_FS_BuildPicker ();
	Fdr_FS_SyncPicker ();
	if (Atr_FS_Picker) then Atr_FS_Picker:Show(); end

	Atr_FullScanFrame:Show();
	Atr_FullScanFrame:SetBackdropColor (0, 0, 0, 100);

	Fdr_FS_Status ("");
	Atr_UpdateFullScanFrame ();
end


function Atr_UpdateFullScanFrame ()

	if (Atr_FullScanDBsize and Atr_GetDBsize) then
		Atr_FullScanDBsize:SetText (Atr_GetDBsize());
	end

	if (Atr_FullScanDBwhen) then
		if (AUCTIONATOR_LAST_SCAN_TIME and date) then
			Atr_FullScanDBwhen:SetText (date ("%A, %B %d at %I:%M %p", AUCTIONATOR_LAST_SCAN_TIME));
		else
			Atr_FullScanDBwhen:SetText (FT("Never"));
		end
	end

	-- Upstream showed a 15-minute countdown to the next getAll. We never call
	-- getAll, so that timer is meaningless; the useful number is how much has
	-- been asked for.
	if (Atr_FullScanNextLabel) then Atr_FullScanNextLabel:SetText (FT("Scans to run:")); end
	if (Atr_FullScanNext) then
		Atr_FullScanNext:SetText (tostring (#Fdr_FS_SelectedClasses ()));
	end

	Fdr_FS_UpdateButtons ();
end


function Atr_FullScanStart ()

	if (Fdr_FS_Running ()) then
		Fdr_FS_Cancel (false);
		return;
	end

	local sel = Fdr_FS_SelectedClasses ();

	if (#sel == 0) then
		Fdr_FS_Status (FT("Select at least one category."));
		return;
	end

	gFS_Queue	= sel;
	gFS_Index	= 0;
	gFS_Added	= 0;
	gFS_Updated	= 0;
	gFS_Skipped	= 0;
	gFS_Variants = 0;
	gFS_Bazaar	= (Atr_FS_BazaarCheck and Atr_FS_BazaarCheck:GetChecked()) and true or false;

	Fdr_FS_UpdateButtons ();
	Fdr_FS_Next ();
end


-- THE BUTTON KEEPS ITS XML LABEL, "Full Scan..." (owner, 2026-08-22).  Nothing
-- relabels it here any more, and this note is what is left of the attempt --
-- kept rather than deleted, because the next person to read this file will have
-- the same idea and the history is the answer to it.
--
-- SUPERSEDED REASONING: this file used to retitle the button to "Scan
-- Categories...", on the grounds that "Full Scan..." is a misnomer once gear is
-- excluded and the scan is category-driven.  That is still true of what the
-- button DOES; it is simply not what the owner wants it called.
--
-- AND IT NEVER ACTUALLY RAN, which is the part worth keeping.  The retitle was a
-- bare `if` at FILE SCOPE, and at file scope Atr_FullScanButton does not exist:
-- the button is created with Atr_Main_Panel from Atr_Sell_Template inside
-- Atr_Init, which does not run until Blizzard_AuctionUI loads, long after this
-- file is parsed.  So the guard was always false and the button read "Full
-- Scan..." for as long as it has existed.  It was made to work on 2026-08-22,
-- the owner saw the new label for the first time, and asked for the old one
-- back -- so the label is now what it always was in practice, and this time on
-- purpose rather than by accident.
-- FINDER_TAB end: full scan replacement
