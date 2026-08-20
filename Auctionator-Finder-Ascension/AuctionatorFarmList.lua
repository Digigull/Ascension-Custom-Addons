--[[--------------------------------------------------------------------------

AuctionatorFarmList.lua -- the farm list, on a minimap button.  BACKLOG item 34.

WHAT IT IS.  A window listing what you ticked onto the Advisor's farm list, and
a minimap button to open it with.  That is the whole feature, and the reason it
is worth a file is WHERE it is used: a farm list is read in the field, and the
auction house is the one place you are certainly not standing when you need it.

THE LIST ALREADY EXISTED.  Item 30 stage 2 built the store and the writer --
ticking "Farm list" on a Worth Farming row writes AUCTIONATOR_ADVISOR.farm, and
Atr_Advisor_FarmList() returns it sorted.  What did not exist was anywhere to
READ it away from the auction house.  So this file is a READER, NOT A SECOND
STORE: the only thing it writes is Atr_Advisor_SetFarmed(name, false), which is
you ticking something off.  Two lists of what to farm that could disagree would
be worse than no window at all.

WHY IT IS ITS OWN FILE AND NOT A THIRD ADVISOR STAGE.  It is the first piece of
this addon's UI that lives OUTSIDE the auction house window -- no AuctionFrame
parent, no tab -- so FRAMEWORK.md section 4's "build in World 2" rule does not
cover it: it is in neither world.  Everything that follows from that is a
difference from every other window here, and each one is a trap:

  * IT CANNOT INITIALISE FROM Atr_Init.  That runs when Blizzard_AuctionUI
    loads, which on a fresh login is the first time you walk up to an
    auctioneer -- so a minimap button built there would not exist until you had
    already been to the place the button exists to save you a trip to.  This
    file owns its own PLAYER_LOGIN frame and builds at login, like the merchant
    and profession harvesters own theirs.

  * IT IS PARKED ON SCREEN WHILE YOU PLAY, which is the LOW + frame level 100
    case in management/docs/CLAUDE.md's strata table -- the cpp meter case, not
    the dialog case.  MEDIUM would cover a character sheet opened by keybind,
    and this window is open exactly while you are opening bags and looting.
    LOW without the frame level is drawn through by health bars and action
    buttons, which is why the pair is not optional.

  * NOTHING HERE CALLS SetToplevel(true), ever.  See DRAG-FREEZE.md.

THE RATE IS STORED, NOT RECOMPUTED, and this is the one honest limit the item
was written around.  What made something worth farming was a gold-per-day figure
at the auction house's prices; you are reading this list somewhere with no
auction house, and the number has been going stale since the moment you walked
away.  So the entry keeps the rate AS IT WAS when you ticked it, with its date,
and the window prints both -- "about 12g a day, ticked 3 days ago".  A
live-looking number that is three days old is worse than an obviously old one.

A FARM LIST IS NOT A SHOPPING LIST, and the two must never merge.  The Reagents
view's bill says what to BUY; this says what to GO AND GET.  The same item can
honestly be on both, and that is not a bug to reconcile.

NO LIBRARY.  LibDBIcon is the usual answer to a minimap button and this addon
ships no Ace libraries at all; the conventions it has to meet -- drag around the
ring, a saved angle, a right-click that does something -- are about sixty lines,
which is cheaper than the first vendored library.

WHAT IT EXPORTS

    Atr_Farm_Init()             builds the button (its own PLAYER_LOGIN frame)
    Atr_Farm_Toggle()           show/hide the window
    Atr_Farm_Refresh()          repaint the window and the button's count --
                                called BY Atr_Advisor_SetFarmed, so ticking
                                anywhere updates everything
    Atr_Farm_ShowMinimap(on)    show/hide the minimap button
    Atr_Farm_Lines()            the window's contents as strings -- no UI, so
                                what it would say can be read without a client

--------------------------------------------------------------------------]]--

local addonName, addonTable = ...;
local zc = addonTable and addonTable.zc or _G.zc;

local function FZT (s)
	if (ZT) then return ZT (s); end
	return s;
end

local FARM_ROWS			= 14;			-- rows before the "...and N more" line.  The
										-- same shape as the Advisor's Ignored box, and
										-- for the same reason: a list you tick off from
										-- the top shortens as you use it, so paging
										-- machinery would be built for a state that
										-- lasts one afternoon.
local FARM_ICON			= 18;
local FARM_ROW_H		= 22;
local FARM_W			= 300;
local FARM_NOTE_W		= 118;			-- the rate-and-age column, right-justified

local FARM_MM_SIZE		= 31;			-- the stock minimap button footprint
local FARM_MM_RADIUS	= 80;			-- ...and the stock ring it sits on
local FARM_MM_ICON		= "Interface\\Icons\\INV_Misc_Herb_07";
local FARM_MM_ANGLE		= 200;			-- degrees, and the default is chosen to land
										-- below-left of the minimap where the stock
										-- buttons are not

local FARM_GOLD			= "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:4:0|t";
local FARM_SILVER		= "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:4:0|t";

local gFarm_Button	= nil;
local gFarm_Window	= nil;

-------------------------------------------------------------------------------
-- what it reads, and the little it remembers about itself
-------------------------------------------------------------------------------

-- WHERE THE BUTTON'S ANGLE AND THE WINDOW'S POSITION LIVE, and it is deliberately
-- not a saved variable of their own: two numbers and a boolean do not earn a
-- file, a .toc line and a migration.  They go in a `ui` corner of
-- AUCTIONATOR_ADVISOR -- the store this window is the reader OF -- so the whole
-- feature is one saved table, and a wiped Advisor takes its window's position
-- with it, which is the right coupling.
--
-- Note what is NOT saved: whether the window was open at logout.  A window that
-- reappeared on its own at every login would be this addon deciding it is
-- important, which is a decision for the button.
local function Farm_UI ()

	if (type (Atr_Advisor_DB) ~= "function") then return {}; end

	local db = Atr_Advisor_DB ();
	if (type (db.ui) ~= "table") then db.ui = {}; end

	return db.ui;
end

local function Farm_List ()
	if (type (Atr_Advisor_FarmList) ~= "function") then return {}; end
	return Atr_Advisor_FarmList ();
end

-- Gold and silver, the way the Advisor prints it inside a sentence.  Not shared
-- with Adv_Money: that one is file-local to the Advisor, and this window has to
-- be able to draw with the auction house closed and nothing else on screen --
-- which is the whole point of it -- so it carries its own six lines rather than
-- a dependency on a tab.
local function Farm_Money (c)

	c = tonumber (c);
	if (c == nil) then return nil; end

	if (zc == nil or zc.val2gsc == nil) then return tostring (c); end

	local g, s = zc.val2gsc (c);

	if (g ~= 0) then return string.format ("%d%s", g, FARM_GOLD); end
	return string.format ("%d%s", s, FARM_SILVER);
end

local function Farm_Now ()
	return (type (time) == "function") and time() or 0;
end

-- "today" / "3 days ago".  The age is always printed, even when it is nothing,
-- because a rate with no date on it reads as current -- and this one never is.
local function Farm_Age (t)

	local secs = Farm_Now () - (tonumber (t) or 0);
	local d    = math.floor (secs / 86400);

	if (d < 1) then return FZT("today"); end
	if (d < 2) then return FZT("yesterday"); end

	return string.format (FZT("%dd ago"), d);
end

-- WHAT A ROW SAYS, as data.  Pure: no WoW API, no frames, so the wording and the
-- as-it-was rule can be read and checked without a client -- the same split that
-- made Atr_An_MenuEntries checkable (BACKLOG item 21).
function Atr_Farm_Lines ()

	local list, out = Farm_List (), {};
	local i;

	for i = 1, #list do

		local e    = list[i];
		local gold = Farm_Money (e.gold);

		-- An entry with no rate is one ticked before the rate was stored (or one
		-- whose card could not price it).  Saying "ticked 3d ago" alone is the
		-- honest version; inventing a figure here would be the Advisor computing
		-- something, which is the rule that file is built on.
		local note;
		if (gold) then
			note = string.format (FZT("%s/day, %s"), gold, Farm_Age (e.t));
		else
			note = Farm_Age (e.t);
		end

		table.insert (out, { name = e.name, id = e.id, note = note });
	end

	return out;
end

-------------------------------------------------------------------------------
-- the window
-------------------------------------------------------------------------------

local function Farm_SavePos (f)

	local point, _, rel, x, y = f:GetPoint ();
	if (point == nil) then return; end

	local ui = Farm_UI ();
	ui.win = { p = point, r = rel, x = x, y = y };
end

local function Farm_RestorePos (f)

	local w = Farm_UI ().win;

	f:ClearAllPoints ();

	if (type (w) == "table" and w.p) then
		f:SetPoint (w.p, UIParent, w.r or w.p, w.x or 0, w.y or 0);
	else
		f:SetPoint ("CENTER", UIParent, "CENTER", 0, 0);
	end
end

local function Farm_BuildRow (f, i)

	local row = CreateFrame ("Button", "Atr_Farm_Row"..i, f);
	row:SetSize (FARM_W - 28, FARM_ROW_H);
	row:SetPoint ("TOPLEFT", 14, -52 - (i - 1) * FARM_ROW_H);
	row:Hide ();

	local icon = row:CreateTexture (nil, "ARTWORK");
	icon:SetSize (FARM_ICON, FARM_ICON);
	icon:SetPoint ("LEFT", 0, 0);
	row.icon = icon;

	-- The tick is the only writer in this file: it takes the item OFF the list.
	-- A checkbox rather than a button because ticking a thing off is the gesture
	-- the object is named after, and because a button labelled "Done" would need
	-- a word in every locale to say what an empty box already says.
	local tick = CreateFrame ("CheckButton", nil, row, "UICheckButtonTemplate");
	tick:SetSize (20, 20);
	tick:SetPoint ("RIGHT", 0, 0);
	tick:SetScript ("OnClick", function (self)
		-- Straight back out of the box: the row is about to disappear, so a
		-- ticked state nobody will see is not worth leaving behind, and if the
		-- write fails the row stays and the box is honest about it.
		self:SetChecked (false);
		if (row.itemName and type (Atr_Advisor_SetFarmed) == "function") then
			Atr_Advisor_SetFarmed (row.itemName, false);
		end
	end);
	tick:SetScript ("OnEnter", function (self)
		if (GameTooltip == nil) then return; end
		GameTooltip:SetOwner (self, "ANCHOR_TOPLEFT");
		GameTooltip:SetText (FZT("Got it"), 1, 1, 1);
		GameTooltip:AddLine (FZT("Take this off the farm list. It stays on the Advisor's suggestions -- this is not Ignore."), 0.8, 0.8, 0.8, true);
		GameTooltip:Show ();
	end);
	tick:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide (); end end);
	row.tick = tick;

	local note = row:CreateFontString (nil, "ARTWORK", "GameFontHighlightSmall");
	note:SetPoint ("RIGHT", tick, "LEFT", -4, 0);
	note:SetWidth (FARM_NOTE_W);
	note:SetHeight (FARM_ICON);
	note:SetJustifyH ("RIGHT");
	note:SetTextColor (0.7, 0.7, 0.7);
	row.note = note;

	local nm = row:CreateFontString (nil, "ARTWORK", "GameFontNormalSmall");
	nm:SetPoint ("LEFT", icon, "RIGHT", 6, 0);
	nm:SetPoint ("RIGHT", note, "LEFT", -6, 0);
	nm:SetHeight (FARM_ICON);		-- one line: a long name clips rather than wraps
	nm:SetJustifyH ("LEFT");
	row.nm = nm;

	-- Hover is the item, the way every other item row in this addon behaves.
	-- There is no click-through to the Analysis tab here on purpose: the auction
	-- house is shut, so a jump to a tab inside it would do nothing at all.
	row:SetScript ("OnEnter", function (self)
		if (self.link and GameTooltip) then
			GameTooltip:SetOwner (self, "ANCHOR_RIGHT");
			GameTooltip:SetHyperlink (self.link);
			GameTooltip:Show ();
		end
	end);
	row:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide (); end end);

	return row;
end

local function Farm_EnsureWindow ()

	if (gFarm_Window) then return gFarm_Window; end
	if (type (CreateFrame) ~= "function") then return nil; end

	local f = CreateFrame ("Frame", "Atr_Farm_Window", UIParent);

	-- LOW + 100, and NOT toplevel.  See the header: this is the window-parked-on-
	-- screen case from the strata table, and the level is what keeps it clear of
	-- Blizzard's bars and unit frames, which live on LOW themselves.
	f:SetFrameStrata ("LOW");
	f:SetFrameLevel (100);

	f:SetSize (FARM_W, 76 + FARM_ROWS * FARM_ROW_H);
	f:EnableMouse (true);
	f:SetMovable (true);
	f:SetClampedToScreen (true);
	f:RegisterForDrag ("LeftButton");
	f:SetScript ("OnDragStart", function (self) self:StartMoving (); end);
	f:SetScript ("OnDragStop", function (self)
		self:StopMovingOrSizing ();
		Farm_SavePos (self);
	end);

	if (f.SetBackdrop) then
		f:SetBackdrop ({
			bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
			insets   = { left = 1, right = 1, top = 1, bottom = 1 },
		});
		f:SetBackdropColor (0.05, 0.05, 0.07, 0.95);
		f:SetBackdropBorderColor (0.30, 0.30, 0.34, 1);
	end

	local title = f:CreateFontString (nil, "OVERLAY", "GameFontNormal");
	title:SetPoint ("TOP", 0, -10);
	title:SetText (FZT("Farm list"));
	f.title = title;

	local note = f:CreateFontString (nil, "OVERLAY", "GameFontHighlightSmall");
	note:SetPoint ("TOP", title, "BOTTOM", 0, -3);
	note:SetText (FZT("Rates are as they were when you ticked them."));
	note:SetTextColor (0.6, 0.6, 0.6);

	local close = CreateFrame ("Button", nil, f, "UIPanelCloseButton");
	close:SetPoint ("TOPRIGHT", -2, -2);

	f.rows = {};
	local i;
	for i = 1, FARM_ROWS do
		f.rows[i] = Farm_BuildRow (f, i);
	end

	f.foot = f:CreateFontString (nil, "OVERLAY", "GameFontDisableSmall");
	f.foot:SetPoint ("BOTTOM", 0, 10);
	f.foot:SetWidth (FARM_W - 24);

	Farm_RestorePos (f);
	f:Hide ();

	gFarm_Window = f;
	return f;
end

local function Farm_Paint ()

	local f = gFarm_Window;
	if (f == nil or not f:IsShown ()) then return; end

	local lines = Atr_Farm_Lines ();

	local i;
	for i = 1, FARM_ROWS do

		local row = f.rows[i];
		local e   = lines[i];

		if (e == nil) then
			row.itemName = nil;
			row.link = nil;
			row:Hide ();
		else
			local tex, id = "Interface\\Icons\\INV_Misc_QuestionMark", e.id;
			if (type (Atr_Advisor_IconFor) == "function") then
				tex, id = Atr_Advisor_IconFor (e.name, e.id);
			end

			row.itemName = e.name;
			row.icon:SetTexture (tex);
			row.nm:SetText (e.name or "?");
			row.note:SetText (e.note or "");
			row.tick:SetChecked (false);

			row.link = nil;
			if (id and type (GetItemInfo) == "function") then
				row.link = select (2, GetItemInfo (id));
			end

			row:Show ();
		end
	end

	f.title:SetText (string.format (FZT("Farm list (%d)"), #lines));

	if (#lines == 0) then
		f.foot:SetText (FZT("Nothing on it yet. Tick Farm list on the Advisor's Worth farming card."));
	elseif (#lines > FARM_ROWS) then
		f.foot:SetText (string.format (FZT("...and %d more. Tick some off to see the rest."), #lines - FARM_ROWS));
	else
		f.foot:SetText ("");
	end
end

-------------------------------------------------------------------------------
-- the minimap button
-------------------------------------------------------------------------------

local function Farm_Angle ()
	local a = tonumber (Farm_UI ().mmAngle);
	if (a == nil) then return FARM_MM_ANGLE; end
	return a;
end

-- Where on the ring.  Kept as an angle rather than an offset because that is
-- what survives a minimap the player has moved or rescaled, and because it is
-- one number to save.
local function Farm_PlaceButton ()

	local b = gFarm_Button;
	if (b == nil or Minimap == nil) then return; end

	local a = math.rad (Farm_Angle ());

	b:ClearAllPoints ();
	b:SetPoint ("CENTER", Minimap, "CENTER",
				FARM_MM_RADIUS * math.cos (a), FARM_MM_RADIUS * math.sin (a));
end

-- Dragging: the angle is read off the cursor every frame while the button is
-- held.  GetCursorPosition is in screen pixels and the minimap's centre is in
-- its own scale, so one of them has to be converted or the button trails the
-- cursor on any UI scale but 1.
local function Farm_DragUpdate (self)

	if (Minimap == nil or type (GetCursorPosition) ~= "function") then return; end

	local mx, my = Minimap:GetCenter ();
	if (mx == nil) then return; end

	local scale = Minimap:GetEffectiveScale ();
	if (scale == nil or scale == 0) then scale = 1; end

	local px, py = GetCursorPosition ();
	px, py = px / scale, py / scale;

	Farm_UI ().mmAngle = math.deg (math.atan2 (py - my, px - mx));
	Farm_PlaceButton ();
end

local function Farm_EnsureButton ()

	if (gFarm_Button) then return gFarm_Button; end
	if (type (CreateFrame) ~= "function" or Minimap == nil) then return nil; end

	local b = CreateFrame ("Button", "Atr_Farm_MinimapButton", Minimap);
	b:SetSize (FARM_MM_SIZE, FARM_MM_SIZE);
	-- MEDIUM + level 8 is what every minimap button in the game does, LibDBIcon's
	-- included, and it is not the strata rule in CLAUDE.md's table being broken:
	-- that rule is about WINDOWS covering what you are working in.  This is a
	-- 31px button pinned to the minimap, it covers nothing, and it never raises.
	b:SetFrameStrata ("MEDIUM");
	b:SetFrameLevel (8);
	b:RegisterForClicks ("LeftButtonUp", "RightButtonUp");
	b:RegisterForDrag ("LeftButton");
	b:SetMovable (true);

	local icon = b:CreateTexture (nil, "BACKGROUND");
	icon:SetSize (20, 20);
	icon:SetPoint ("TOPLEFT", 7, -6);
	icon:SetTexture (FARM_MM_ICON);
	icon:SetTexCoord (0.07, 0.93, 0.07, 0.93);		-- crop the icon's own border

	local ring = b:CreateTexture (nil, "OVERLAY");
	ring:SetSize (53, 53);
	ring:SetPoint ("TOPLEFT", 0, 0);
	ring:SetTexture ("Interface\\Minimap\\MiniMap-TrackingBorder");

	b:SetHighlightTexture ("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight");

	-- How many are on the list, on the button.  It is the one thing you want to
	-- know without opening anything, and an empty list says nothing rather than
	-- "0" -- a zero badge is a badge you learn to ignore.
	local count = b:CreateFontString (nil, "OVERLAY", "NumberFontNormalSmall");
	count:SetPoint ("BOTTOMRIGHT", -4, 6);
	b.count = count;

	b:SetScript ("OnDragStart", function (self)
		self:SetScript ("OnUpdate", Farm_DragUpdate);
	end);
	b:SetScript ("OnDragStop", function (self)
		self:SetScript ("OnUpdate", nil);
	end);

	-- RIGHT-CLICK HIDES THE BUTTON, and that is the whole of the right-click
	-- menu.  BACKLOG item 21 is why: UIDropDownMenu is driven by four globals
	-- every other addon writes, it fails by drawing nothing, and no offline check
	-- in this repo can reach any of it -- three rounds of the client were spent
	-- learning that once.  A menu whose only real entry is "hide" is not worth
	-- re-entering that.  The chat line names the way back, because a button that
	-- vanishes with no way to return is the actual trap here.
	b:SetScript ("OnClick", function (self, button)
		if (button == "RightButton") then
			Atr_Farm_ShowMinimap (false);
			if (zc and zc.msg_atr) then
				zc.msg_atr (FZT("Farm list button hidden. /atrfarm minimap brings it back."));
			end
			return;
		end
		Atr_Farm_Toggle ();
	end);

	b:SetScript ("OnEnter", function (self)
		if (GameTooltip == nil) then return; end
		GameTooltip:SetOwner (self, "ANCHOR_LEFT");
		GameTooltip:SetText (FZT("Farm list"), 1, 1, 1);
		GameTooltip:AddLine (string.format (FZT("%d on the list."), #Farm_List ()), 0.8, 0.8, 0.8);
		GameTooltip:AddLine (FZT("Left-click to open, drag to move, right-click to hide the button."), 0.6, 0.6, 0.6, true);
		GameTooltip:Show ();
	end);
	b:SetScript ("OnLeave", function () if (GameTooltip) then GameTooltip:Hide (); end end);

	gFarm_Button = b;
	Farm_PlaceButton ();

	return b;
end

-------------------------------------------------------------------------------
-- the surface
-------------------------------------------------------------------------------

function Atr_Farm_Refresh ()

	local b = gFarm_Button;
	if (b and b.count) then
		local n = #Farm_List ();
		b.count:SetText ((n > 0) and tostring (n) or "");
	end

	Farm_Paint ();
end

function Atr_Farm_Show ()

	local f = Farm_EnsureWindow ();
	if (f == nil) then return; end

	f:Show ();
	Atr_Farm_Refresh ();
end

function Atr_Farm_Hide ()
	if (gFarm_Window) then gFarm_Window:Hide (); end
end

function Atr_Farm_Toggle ()

	if (gFarm_Window and gFarm_Window:IsShown ()) then
		Atr_Farm_Hide ();
		return;
	end

	Atr_Farm_Show ();
end

function Atr_Farm_ShowMinimap (on)

	Farm_UI ().mmHidden = (not on) and true or nil;

	local b = Farm_EnsureButton ();
	if (b == nil) then return; end

	if (on) then b:Show (); else b:Hide (); end
end

function Atr_Farm_Init ()

	local b = Farm_EnsureButton ();
	if (b == nil) then return; end

	if (Farm_UI ().mmHidden) then b:Hide (); end

	Atr_Farm_Refresh ();
end

-------------------------------------------------------------------------------
-- wiring
-------------------------------------------------------------------------------

-- PLAYER_LOGIN, not Atr_Init: see the header.  Atr_Init runs when
-- Blizzard_AuctionUI loads, which is the first auctioneer you speak to, and a
-- minimap button that appears only after a trip to the auction house has missed
-- the point of being on the minimap.
if (type (CreateFrame) == "function") then

	local ev = CreateFrame ("Frame", "Atr_FarmListLoader", UIParent);
	ev:RegisterEvent ("PLAYER_LOGIN");
	ev:SetScript ("OnEvent", function (self)
		self:UnregisterEvent ("PLAYER_LOGIN");
		Atr_Farm_Init ();
	end);
end

if (SlashCmdList) then

	SLASH_ATRFARM1 = "/atrfarm";

	SlashCmdList["ATRFARM"] = function (msg)

		msg = string.lower (tostring (msg or "")):gsub ("^%s+", ""):gsub ("%s+$", "");

		if (msg == "minimap") then
			Atr_Farm_ShowMinimap (true);
			return;
		end

		if (msg == "reset") then
			-- Both placements at once, because the case this exists for is "it is
			-- off the edge of my screen and I cannot grab it", and that is not a
			-- state you can be asked to diagnose per window.
			local ui = Farm_UI ();
			ui.mmAngle = nil;
			ui.win = nil;
			Farm_PlaceButton ();
			if (gFarm_Window) then Farm_RestorePos (gFarm_Window); end
			Atr_Farm_ShowMinimap (true);
			return;
		end

		if (msg == "help" or msg == "?") then
			if (zc and zc.msg_atr) then
				zc.msg_atr (FZT("usage: /atrfarm  (open the list)  |  minimap  |  reset"));
			end
			return;
		end

		Atr_Farm_Toggle ();
	end;
end
