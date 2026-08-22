-------------------------------------------------------------------------------
-- AuctionatorFinderOptions.lua
--
-- The Finder's rows on Auctionator's Scanning options panel (the "Prices" feed
-- toggle and friends) plus their event frame.
--
-- It also owns the LAYOUT of everything below y -110 on that panel, which is
-- now more than the Finder's own rows: the Ledger's Clear control is placed
-- here too (built by AuctionatorLedger.lua, which owns what it does).  Anything
-- else that wants a spot on this panel goes through Fdr_Options_Ensure for the
-- same reason -- two files choosing absolute offsets on one panel is how rows
-- end up drawn on top of each other.
--
-- Split out of AuctionatorFinder.lua (was the "scanning options rows" section).
-- Shares only the Buy<->Finder redirect table through addonTable.Finder.Redir;
-- everything else is its own state or reached through globals.
-------------------------------------------------------------------------------

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc;
local F  = addonTable and addonTable.Finder;
local FT = F and F.FT;

-- The Buy<->Finder redirect table, shared by reference (core never reassigns
-- it, only mutates fields), so a re-arm here (gFdr_Redir.skip = nil) is seen
-- by the redirect hooks in the core file.
local gFdr_Redir = F and F.Redir;

-- ===========================================================================
-- FINDER_TAB begin: scanning options rows
--
-- The Finder's price-feed setting lives in Interface > AddOns > Auctionator >
-- Scanning, under the quality floor that governs the same price feed:
--   * Prices   - AUCTIONATOR_FINDER_SETTINGS.feedPriceDB   (default ON)
-- It was a checkbox on the Finder tab's bottom strip until 2026-07.
--
-- TWO TRAPS, both specific to Auctionator's options plumbing:
--   1. Atr_LoadOptionsSubPanel copies the save function into f.okay BY VALUE
--      at XML OnLoad (`f.okay = _G[frameName.."_Save"]`), and Blizzard calls
--      that captured field.  hooksecurefunc on the global name is therefore
--      INERT for the Okay path - the panel's own okay/cancel fields have to
--      be wrapped instead.  AuctionatorConfig.xml is the last file in the
--      toc, so the field is always set before PLAYER_LOGIN gets here.
--   2. Blizzard calls okay() on EVERY registered category when Okay is
--      pressed, whether or not that panel was ever displayed.  So the rows
--      must exist and be in sync from login, not from first display, or the
--      first Okay writes whatever an uninitialised checkbox happened to say.
--
-- Everything is guarded: a build without this panel degrades to "no rows",
-- never to an error, and /atrprices on|off remains as the fallback path to
-- the price-feed setting.
-- ===========================================================================

local gFdr_OptRows = nil;

-- Creates the rows once.  Returns the widget table, or nil when this build
-- has no Scanning panel to hang them on.
function Fdr_Options_Ensure ()

	if (gFdr_OptRows) then return gFdr_OptRows; end

	local panel = _G["Atr_ScanningOptionsFrame"];
	if (panel == nil or CreateFrame == nil or panel.CreateFontString == nil) then return nil; end

	-- The panel's own content ends at the quality-floor dropdown (y -60,
	-- ~32 tall), so -110 down is free.
	local head = panel:CreateFontString (nil, "ARTWORK", "GameFontNormal");
	head:SetPoint ("TOPLEFT", panel, "TOPLEFT", 18, -110);
	head:SetText (FT("Finder scans"));

	local function row (name, y, label, tipTitle, tipLines)

		local cb = CreateFrame ("CheckButton", name, panel, "UICheckButtonTemplate");
		cb:SetWidth (24);
		cb:SetHeight (24);
		cb:SetPoint ("TOPLEFT", panel, "TOPLEFT", 20, y);

		local t = _G[name.."Text"];
		if (t) then t:SetText (" "..label); end

		cb:SetScript ("OnEnter", function (self)
			if (GameTooltip == nil) then return; end
			GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
			GameTooltip:SetText (tipTitle, 1, 1, 1);
			local i;
			for i = 1, #tipLines do
				local ln = tipLines[i];
				if (type (ln) == "table") then
					GameTooltip:AddLine (ln[1], ln[2], ln[3], ln[4]);
				else
					GameTooltip:AddLine (ln, nil, nil, nil, true);
				end
			end
			GameTooltip:Show();
		end);
		cb:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide(); end end);

		return cb;
	end

	gFdr_OptRows = {};

	gFdr_OptRows.prices = row ("Atr_Finder_Opt_Prices_CB", -134,
		FT("Update Auctionator prices from Finder scans"),
		FT("Update Auctionator prices"),
		{ FT("Feeds this scan's lowest buyouts into Auctionator's own price database, so the Buy and Sell tabs stay current without a Full Scan. Scaled gear is excluded (that database is keyed by name, which cannot tell scaled variants apart) and nothing is ever deleted. Skipped entirely when a scan hits the result cap, because a truncated scan's lowest prices are too high."),
		  FT("Scaled gear is not lost, only kept elsewhere: a Full Scan of the Weapon or Armor category reads each listing's own item level as it goes and files the price under that exact version instead (/atrahdb).") });

	gFdr_OptRows.gearjump = row ("Atr_Finder_Opt_GearJump_CB", -160,
		FT("Open weapons and armor on the Finder tab"),
		FT("Gear opens on the Finder tab"),
		{ FT("Picking a weapon or a piece of armor on the Buy tab searches it here instead. The Buy tab groups a scan by item name and shows one cached version for all of it, which on this realm can be a different item than the one you buy; this tab reads each listing's own required level and verifies its real item level. Everything that is not gear still opens on the Buy tab. Searching the same item a second time stays there."),
		  FT("In game use /atrgear.") });

	gFdr_OptRows.knownrecipes = row ("Atr_Finder_Opt_KnownRecipes_CB", -186,
		FT("Hide recipes you have already learned"),
		FT("Hide known recipes"),
		{ FT("Removes recipe listings this character has already learned from Finder results. Decided from the recipe's own tooltip, the same 'Already known' line the client shows you, so it costs nothing until a search actually returns recipes."),
		  FT("Knowing is per character; the preference is shared. When a recipe's item data has not been cached yet the row is kept rather than hidden, so nothing you might want disappears.") });

	-- BACKLOG item 31. Off by default and last in the list, because it is the one
	-- row here that adds a file rather than changing what an existing one holds.
	gFdr_OptRows.history = row ("Atr_Finder_Opt_History_CB", -212,
		FT("Remember what prices used to be"),
		FT("Market price history"),
		{ FT("Records one price a day per item, from the same scans that already feed the price database, so the addon can tell you what something was worth last week and not just today. The History tab on Buy, Sell and My Auctions reads it, and so do the tooltip and the Analysis tab's Week column."),
		  FT("It is kept in a SavedVariables file of its own, so a client crash can never take your trade ledger or your learned vendor prices down with a big history. Deleting that file loses only the history, and scanning grows it back."),
		  FT("Needs the Auctionator-Finder-Ascension-History folder installed beside this addon. In game use /atrhistory.") });

	-- THE LEDGER'S CLEAR CONTROL (owner, 2026-08-22).  Not a Finder scan, and not
	-- a setting at all -- it is a button, and it is on this panel because on the
	-- Ledger tab it sat on the same chrome row as that tab's filter box, where
	-- "Clear" reads as "clear the filter" (AuctionatorLedger.lua's Atr_Ledger_Init
	-- carries the full reasoning).  Options is where a control you have to go
	-- looking for belongs, and going looking is the point for this one.
	--
	-- Its own heading, and a gap above it, so it cannot be skimmed as a fourth
	-- row of the group above.  The button is built by the LEDGER: this file owns
	-- where things sit on this panel, that file owns what clearing means.
	if (type (Atr_Ledger_BuildOptionsButton) == "function") then

		local lhead = panel:CreateFontString (nil, "ARTWORK", "GameFontNormal");
		lhead:SetPoint ("TOPLEFT", panel, "TOPLEFT", 18, -252);
		lhead:SetText (FT("Trade ledger"));

		gFdr_OptRows.ledgerclear = Atr_Ledger_BuildOptionsButton (panel, 20, -276);

		-- Said on the panel, not only in the tooltip: this is the one store here
		-- that scanning cannot grow back, and a consequence nobody hovers to read
		-- has not been given.  Anchored below the button rather than beside it so
		-- the wrap has the panel's whole width and cannot run off the edge.
		local lnote = panel:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
		lnote:SetPoint ("TOPLEFT", panel, "TOPLEFT", 22, -304);
		lnote:SetWidth (560);
		lnote:SetJustifyH ("LEFT");
		lnote:SetText (FT("Deletes your record of what you actually bought and sold. Every other database here regrows by scanning; this one is a record of what happened, so nothing can bring it back. You will be asked to confirm, with the row count."));
	end

	return gFdr_OptRows;
end


-- settings -> widgets.  Global: the slash fallbacks call it too, so a toggle
-- made from chat shows up on an already-open panel.
function Fdr_Options_Sync ()

	local r = Fdr_Options_Ensure ();
	if (r == nil) then return; end

	r.prices:SetChecked (Fdr_PriceDB_Enabled () and true or nil);
	r.gearjump:SetChecked (Fdr_BuyRedirect_Enabled () and true or nil);
	r.knownrecipes:SetChecked ((type (Fdr_HideKnownRecipes_Enabled) == "function")
							   and Fdr_HideKnownRecipes_Enabled () and true or nil);

	-- Ticked only when it is actually recording.  Without the companion addon it
	-- cannot be, so the row is disabled and says why rather than offering a
	-- checkbox that does nothing -- which is the state someone lands in by
	-- updating one folder and not the other.
	if (r.history) then

		local have = (type (Atr_Hist_Available) == "function") and Atr_Hist_Available ();

		r.history:SetChecked (have and (type (Atr_Hist_Enabled) == "function")
									and Atr_Hist_Enabled () and true or nil);

		if (have) then
			r.history:Enable ();
		else
			r.history:Disable ();
		end

		local t = _G["Atr_Finder_Opt_History_CBText"];
		if (t) then
			if (have) then
				t:SetText (" "..FT("Remember what prices used to be"));
			else
				t:SetText (" "..FT("Remember what prices used to be")
							 .."  |cff808080"..FT("(history addon not installed)").."|r");
			end
		end
	end
end


-- widgets -> settings.  Only ever called from the wrapped okay, and only
-- writes when the rows actually exist.
function Fdr_Options_Apply ()

	if (gFdr_OptRows == nil) then return; end

	AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
	AUCTIONATOR_FINDER_SETTINGS.feedPriceDB   = gFdr_OptRows.prices:GetChecked() and true or false;
	AUCTIONATOR_FINDER_SETTINGS.gearToFinder  = gFdr_OptRows.gearjump:GetChecked() and true or false;
	-- through the setter, so the one place that knows the default is OFF stays
	-- the one place that knows it (BACKLOG item 31)
	if (gFdr_OptRows.history and type (Atr_Hist_SetEnabled) == "function") then
		Atr_Hist_SetEnabled (gFdr_OptRows.history:GetChecked());
	end

	-- through the setter, so the Finder's own toolbar checkbox moves with it
	if (type (Atr_Finder_SetHideKnownRecipes) == "function") then
		Atr_Finder_SetHideKnownRecipes (gFdr_OptRows.knownrecipes:GetChecked());
	else
		AUCTIONATOR_FINDER_SETTINGS.hideKnownRecipes = gFdr_OptRows.knownrecipes:GetChecked() and true or false;
	end

	-- the filter only reads its setting at rebuild, so a toggle has to ask for one
	if (type (Atr_Finder_RebuildDisplay) == "function" and Atr_Finder_Panel) then
		Atr_Finder_RebuildDisplay ();
		if (type (Atr_Finder_Redisplay) == "function") then Atr_Finder_Redisplay (); end
	end
end


-- Wraps the panel's okay/cancel (see trap 1) and builds the rows (trap 2).
-- Idempotent, so a second call - or another addon's - cannot double-wrap.
function Fdr_Options_Init ()

	local panel = _G["Atr_ScanningOptionsFrame"];
	if (panel == nil or panel.fdrOptionsWrapped) then return false; end
	panel.fdrOptionsWrapped = true;

	local prevOkay		= panel.okay;
	local prevCancel	= panel.cancel;

	panel.okay = function (...)
		if (prevOkay) then prevOkay (...); end
		Fdr_Options_Apply ();
	end

	panel.cancel = function (...)
		if (prevCancel) then prevCancel (...); end
		Fdr_Options_Sync ();			-- discard our edits along with theirs
	end

	if (panel.HookScript) then
		panel:HookScript ("OnShow", Fdr_Options_Sync);
	end

	Fdr_Options_Sync ();				-- create + fill NOW, not on first display
	return true;
end


-- Chat fallback for the toggles, and the only route on a build whose
-- Scanning panel we could not find.  /atrprices carries the price feed's.
if (SlashCmdList) then
	SLASH_ATRVARIANTDB1 = "/atrahdb";
	SlashCmdList["ATRVARIANTDB"] = function (msg)

		local arg = string.lower (string.gsub (msg or "", "^%s*(.-)%s*$", "%1"));

		if (arg == "on" or arg == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.ahVariant = (arg == "on");
			zc.msg_pink ("Verified auction prices on tooltips: "..(arg == "on" and "ON" or "OFF"));
			return;
		end

		local db = Atr_AHVariantDB and Atr_AHVariantDB ();
		zc.msg_pink ("Verified auction prices: "
			..((Atr_AHVariant_Enabled and Atr_AHVariant_Enabled ()) and "ON" or "OFF")
			.."  ·  "..tostring (db and db.c or 0).." variant(s) known"
			.."  ·  session "..tostring (db and db.s or 0));
		zc.msg_pink ("Use /atrahdb on|off.  Prices come from the Verify button and from a Full");
		zc.msg_pink ("Scan of the Weapon/Armor categories; a '*' on the");
		zc.msg_pink ("Auction line means the price is for that exact scale-variant.");
	end

	SLASH_ATRGEARJUMP1 = "/atrgear";
	SlashCmdList["ATRGEARJUMP"] = function (msg)

		local arg = tostring (msg or ""):lower():match ("%a+");
		if (arg == "on" or arg == "off") then
			AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
			AUCTIONATOR_FINDER_SETTINGS.gearToFinder = (arg == "on");
			gFdr_Redir.skip = nil;			-- a deliberate toggle re-arms it
			Fdr_Options_Sync ();
		end

		local s = "Gear opens on the Finder tab: "..(Fdr_BuyRedirect_Enabled () and
					"|cff40ff40ON|r - weapons and armor picked on the Buy tab search here instead" or
					"|cffff4040OFF|r (Auctionator options > Scanning)");
		if (zc and zc.msg_atr) then zc.msg_atr (s);
		elseif (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage (s); end
	end
end


local gFdr_OptEventFrame = CreateFrame ("Frame", "Atr_Finder_OptionsEventFrame");
gFdr_OptEventFrame:RegisterEvent ("PLAYER_LOGIN");
gFdr_OptEventFrame:SetScript ("OnEvent", function ()
	Fdr_Options_Init ();
end);
-- FINDER_TAB end: scanning options rows
