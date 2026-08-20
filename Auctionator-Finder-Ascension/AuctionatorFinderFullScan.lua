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
-- is hidden, and the category picker is built in Lua in exactly that space.
--
-- WHY GEAR IS EXCLUDED, and why it is not merely unticked but absent:
-- gAtr_ScanDB is keyed by item NAME.  On Ascension one name covers many
-- scaled instances at different item levels, so a single stored price would
-- stand in for every variant and be wrong for all but one.  Rule 2 of the
-- price feed already refuses scaled equipment, so including gear would burn
-- an enormous amount of scan time to store almost nothing.  The Finder tab
-- reads each listing's REAL required level and is the right tool for gear.
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
local gFS_Bazaar	= false;
local gFS_Built		= false;
local gFS_Cancelling = false;	-- re-entrancy guard: the cancel path is mutual



function Fdr_FS_IsGearClass (ci)
	return (ci == FS_WEAPON_CLASS or ci == FS_ARMOR_CLASS);
end


-- Every auction class, gear flagged rather than dropped: the picker shows the
-- gear rows greyed so the exclusion is visible and explained, not silent.
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


-- Gear is refused HERE as well as in the UI, so a hand-edited SavedVariables
-- file cannot smuggle Armor into a run.
function Fdr_FS_IsSelected (ci)

	if (Fdr_FS_IsGearClass (ci)) then return false; end

	local v = Fdr_FS_Store()[tostring (ci)];
	if (v == nil) then return true; end			-- default: every non-gear class
	return v and true or false;
end


function Fdr_FS_SetSelected (ci, on)

	if (Fdr_FS_IsGearClass (ci)) then return false; end

	Fdr_FS_Store()[tostring (ci)] = on and true or false;
	return true;
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
		if (not all[i].gear and Fdr_FS_IsSelected (all[i].ci)) then
			local m = all[i].members or { all[i].ci };
			for j = 1, #m do
				out[#out + 1] = { ci = m[j], name = names[m[j]] or all[i].name };
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
	end
	if (Atr_Bz_CancelCategoryScan) then Atr_Bz_CancelCategoryScan (true); end

	gFS_Cancelling = false;

	if (was and not quiet) then
		Fdr_FS_Status (string.format (FT("Stopped - %d new, %d updated"), gFS_Added, gFS_Updated));
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

	Fdr_FS_Status (string.format (FT("Done: %d %s, %d new, %d updated"),
					n, (n == 1) and FT("category") or FT("categories"),
					gFS_Added, gFS_Updated));

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

	Fdr_FS_Status (string.format (FT("Scanning %s (%d of %d)"),
					entry.name or "?", gFS_Index, #gFS_Queue));

	local spec = { class = entry.ci, subclass = nil, autoAccept = true, label = entry.name };

	local started = Atr_Finder_StartQueueScan ({ spec }, function (added, updated, skipped)
			gFS_Added	= gFS_Added + (added or 0);
			gFS_Updated	= gFS_Updated + (updated or 0);
			gFS_Skipped	= gFS_Skipped + (skipped or 0);
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

function Fdr_FS_BuildPicker ()

	if (gFS_Built) then return true; end
	if (not (Atr_FullScanFrame and CreateFrame)) then return false; end

	local panel = CreateFrame ("Frame", "Atr_FS_Picker", Atr_FullScanFrame);
	panel:SetPoint ("TOPLEFT", 27, -175);
	panel:SetWidth (405);
	panel:SetHeight (300);

	local head = panel:CreateFontString ("Atr_FS_PickerHead", "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", 0, 0);
	head:SetText (FT("Categories to scan"));

	local all = Fdr_FS_Classes ();

	-- balance the two columns instead of hardcoding a wrap: the class list is
	-- not stock here (Ascension appends "Quest") and merging shortens it again
	local perCol = math.ceil (#all / 2);
	if (perCol < 1) then perCol = 1; end

	local col, row = 0, 0;
	local i;

	for i = 1, #all do

		local e	  = all[i];
		local cb  = CreateFrame ("CheckButton", "Atr_FS_Cat"..e.ci, panel, "UICheckButtonTemplate");
		local txt = _G["Atr_FS_Cat"..e.ci.."Text"];

		cb:SetSize (20, 20);
		cb:SetPoint ("TOPLEFT", col * 200, -22 - (row * 22));

		-- a merged row says what it now covers, so the fold is not a surprise
		local label = e.name or ("#"..e.ci);
		if (e.members and #e.members > 1) then
			label = label.." |cff808080+|r";
		end

		if (txt) then txt:SetText (label); end

		if (e.gear) then
			-- present but refused: the exclusion has to be visible to be honest
			cb:SetChecked (nil);
			cb:Disable();
			if (txt) then txt:SetText ("|cff808080"..label.."|r"); end
		else
			cb:SetChecked (Fdr_FS_IsSelected (e.ci) and true or nil);
			cb:SetScript ("OnClick", function (self)
					Fdr_FS_SetSelected (e.ci, self:GetChecked() and true or false);
					if (Atr_UpdateFullScanFrame) then Atr_UpdateFullScanFrame (); end
				end);

			if (e.members and #e.members > 1 and GameTooltip) then
				local names = (Atr_GetAuctionClasses and Atr_GetAuctionClasses ()) or {};
				local parts, k = {}, nil;
				for k = 1, #e.members do parts[k] = names[e.members[k]] or "?"; end
				local tip = table.concat (parts, ", ");
				cb:SetScript ("OnEnter", function (self)
						GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
						GameTooltip:SetText (FT("Scans: ")..tip, 1, 1, 1);
						GameTooltip:Show();
					end);
				cb:SetScript ("OnLeave", function () GameTooltip:Hide(); end);
			end
		end

		row = row + 1;
		if (row >= perCol) then row = 0; col = col + 1; end
	end

	local yBase = -22 - (perCol * 22) - 10;

	local bz = CreateFrame ("CheckButton", "Atr_FS_BazaarCheck", panel, "UICheckButtonTemplate");
	bz:SetSize (20, 20);
	bz:SetPoint ("TOPLEFT", 0, yBase);
	bz:SetChecked (nil);
	if (_G["Atr_FS_BazaarCheckText"]) then
		_G["Atr_FS_BazaarCheckText"]:SetText (FT("Also price the Bazaar catalogue"));
	end

	-- The exclusion, spelled out. 3.3.5 FontStrings wrap once a width is set
	-- and nothing clips them, so the width is fixed and the height is not.
	local why = panel:CreateFontString ("Atr_FS_WhyNoGear", "ARTWORK", "GameFontNormalSmall");
	why:SetPoint ("TOPLEFT", 0, yBase - 30);
	why:SetWidth (395);
	why:SetJustifyH ("LEFT");
	why:SetText ("|cffffcc00"..FT("Weapons and Armor are not scanned.").."|r  "
				..FT("Auctionator's price database is keyed by item NAME. On Ascension "
					.."one name covers many scaled versions at different item levels, so a "
					.."single stored price would stand in for every version and be wrong "
					.."for all but one. Use the Finder tab for gear."));

	gFS_Built = true;
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
	gFS_Bazaar	= (Atr_FS_BazaarCheck and Atr_FS_BazaarCheck:GetChecked()) and true or false;

	Fdr_FS_UpdateButtons ();
	Fdr_FS_Next ();
end


-- "Full Scan..." is a misnomer once gear is excluded and the scan is
-- category-driven, so relabel the More... entry to match what it does.
--
-- A FUNCTION, CALLED FROM Atr_Init, AND IT USED TO BE NEITHER.  This was a bare
-- `if` at file scope, and at file scope Atr_FullScanButton DOES NOT EXIST: the
-- button is created with Atr_Main_Panel from the Atr_Sell_Template, inside
-- Atr_Init, which does not run until Blizzard_AuctionUI loads -- long after this
-- file is parsed.  So the guard was always false and the button has been reading
-- "Full Scan..." ever since, which is exactly what the owner called it when
-- asking for BACKLOG item 6.  Found 2026-08-22 while moving the button.
function Fdr_FS_RelabelButton ()
	if (Atr_FullScanButton and Atr_FullScanButton.SetText) then
		Atr_FullScanButton:SetText (FT("Scan Categories..."));
	end
end
-- FINDER_TAB end: full scan replacement
