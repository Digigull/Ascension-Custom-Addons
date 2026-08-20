-- callboard-smoke.lua -- offline check for the Call Board capture (BACKLOG 28).
--
-- WHY THIS ONE EXISTS, when the house rule is not to build harnesses: the store
-- is a ONE-WAY DOOR.  A week captured wrong cannot be recaptured -- the board
-- has rotated -- so the parsers get one chance at each week, and every string
-- below is copied verbatim out of the owner's 2026-08-20 stage 0 dump rather
-- than invented.  It stubs four client functions and nothing else; it is not a
-- client emulation and must not grow into one.
--
--   lua5.1 management/addons/auctionator/tools/callboard-smoke.lua

local pass, fail = 0, 0;

local function ok (cond, what)
	if (cond) then pass = pass + 1;
	else fail = fail + 1; print ("FAIL: " .. tostring (what)); end
end

local function eq (got, want, what)
	if (got == want) then pass = pass + 1;
	else fail = fail + 1; print (string.format ("FAIL: %s -- got %s, want %s",
	                                            tostring (what), tostring (got), tostring (want))); end
end

time = function () return 1755648000; end   -- a fixed 2025 instant; only the bucket matters
date = os.date;

-- ---------------------------------------------------------------- the client

-- Verbatim from the dump: the quest log at a Hero's Call Board, headers and all.
-- Nine returns, the ninth a questID, which is Ascension's addition.
local LOG = {
	{ "Ascension",                                        0, nil, 0, 1,   nil, nil, nil, 0 },
	{ "Dirge's Nevermelt Ice Cream",                      60, nil, 0, nil, nil, nil, nil, 100503 },
	{ "Ascension (Profession)",                           0, nil, 0, 1,   nil, nil, nil, 0 },
	{ "Arms Dealer: Enchant Weapon - Unstoppable Assault", 60, nil, 0, nil, nil, nil, 1, 80840 },
	{ "A Delicate Situation: Dark Iron Bar",              70, nil, 0, nil, nil, nil, 1, 1005059 },
	{ "A Delicate Situation: Dense Stone",                70, nil, 0, nil, nil, nil, 1, 1005094 },
	{ "Blasted Lands",                                    0, nil, 0, 1,   nil, nil, nil, 0 },
	{ "The Stones That Bind Us",                          57, nil, 0, nil, nil, nil, nil, 2681 },
};

local OBJ = {
	[2] = { { "Shard of Nevermelting Ice: 0/10", "item" }, { "Ice Cold Milk: 0/10", "item" } },
	[4] = { { "Scroll of Enchant Weapon - Unstoppable Assault: 0/1", "item" } },
	[5] = { { "Dark Iron Bar: 0/1", "item" } },
	[6] = { { "Dense Stone: 3/40", "item" } },
	[8] = { { "Servants of Razelikh Freed: 0/9", "monster" }, { "Servants of Grol Freed: 0/3", "monster" } },
};

GetNumQuestLogEntries    = function () return #LOG, 5; end
GetQuestLogTitle         = function (i) local r = LOG[i]; if (r == nil) then return nil; end
                                        return r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]; end
GetNumQuestLeaderBoards  = function (i) return OBJ[i] and #OBJ[i] or 0; end
GetQuestLogLeaderBoard   = function (j, i) local o = OBJ[i] and OBJ[i][j];
                                        if (o == nil) then return nil; end return o[1], o[2], nil; end

-- The gossip lists, flat, exactly as the dump reported them: 5 values a quest
-- available, 4 a quest active.
GetNumGossipAvailableQuests = function () return 1; end
GetGossipAvailableQuests    = function () return "A True Artisan: Titanic Leggings", 70, nil, nil, nil; end
GetNumGossipActiveQuests    = function () return 3; end
GetGossipActiveQuests       = function ()
	return "Arms Dealer: Enchant Weapon - Unstoppable Assault", 60, nil, nil,
	       "A Delicate Situation: Dark Iron Bar", 70, nil, nil,
	       "A Delicate Situation: Dense Stone", 70, nil, nil;
end

-- The board is up.
local boardVisible = true;
CallBoardUI = { IsVisible = function () return boardVisible; end };

-- ------------------------------------------------------------------ the file

local chunk = assert (loadfile ("Auctionator-Finder-Ascension/AuctionatorCallBoard.lua"));
chunk ("Auctionator", {});

-- ------------------------------------------------------------------- the run

ok (Atr_CB_BoardUp (), "board detected as up");
ok (Atr_CB_Harvest (), "harvest filed something");

local wk   = Atr_CB_Week ();
local week = AUCTIONATOR_CALLBOARD.weeks[wk];

ok (week ~= nil, "this week's bucket exists");
eq (Atr_CB_Week (), Atr_CB_Week (time ()), "week defaults to now");

local q = week.q;

-- Every gossip quest is filed, taken or not.
ok (q["A True Artisan: Titanic Leggings"]  ~= nil, "available quest filed");
ok (q["A Delicate Situation: Dense Stone"] ~= nil, "active quest filed");
ok (q["Arms Dealer: Enchant Weapon - Unstoppable Assault"] ~= nil, "second active filed");

-- Nothing that was not on the board.
ok (q["Dirge's Nevermelt Ice Cream"] == nil, "ordinary Ascension quest NOT filed");
ok (q["The Stones That Bind Us"]     == nil, "ordinary zone quest NOT filed");

-- The join: the log supplies the item and the count gossip cannot.
local dense = q["A Delicate Situation: Dense Stone"];
eq (dense.it["Dense Stone"], 40, "count comes from the objective, not the progress");
eq (dense.id,  1005094,             "questID captured from return nine");
eq (dense.cat, "Ascension (Profession)", "header captured as the category");
eq (dense.kind, "d",                "isDaily captured");

local scroll = q["Arms Dealer: Enchant Weapon - Unstoppable Assault"];
eq (scroll.it["Scroll of Enchant Weapon - Unstoppable Assault"], 1,
    "an item name containing a dash and no colon survives");
eq (scroll.id, 80840, "second questID");

-- A quest gossip offers but the player has not taken has no count yet.
local artisan = q["A True Artisan: Titanic Leggings"];
eq (next (artisan.it), nil, "unaccepted quest carries no count from the log");

-- ... which is what the tooltip is for.  Verbatim from the dump.
ok (Atr_CB_NoteTooltip ({
	owner = "CallBoardUI.content.ExtraSlotsContent.categoryDetailsFrameQuest3",
	lines = {
		"A Delicate Situation: Dense Stone",
		"You are on this quest",
		" ",
		"Collect 40 Dense Stones.",
		" ",
		"Requirements:",
		" - Dense Stone x 40",
		" ",
		"Rewards",
		" - Rune of Ascension  |  2000  ",
	},
}), "tooltip requirement parsed");

eq (q["A Delicate Situation: Dense Stone"].it["Dense Stone"], 40, "tooltip agrees with the log");

-- The reward line must never be read as a requirement.
eq (q["A Delicate Situation: Dense Stone"].it["Rune of Ascension"], nil,
    "the Rewards block is not harvested as demand");

-- A tooltip that is not a board card is ignored outright.
ok (not Atr_CB_NoteTooltip ({
	owner = "ContainerFrame1Item3",
	lines = { "Dense Stone", "Requirements:", " - Dense Stone x 40" },
}), "a bag tooltip is not a call board card");
ok (q["Dense Stone"] == nil, "and files nothing");

-- Progress must never overwrite the requirement downward.
Atr_CB_Note ("A Delicate Situation: Dense Stone", { item = "Dense Stone", need = 3 });
eq (q["A Delicate Situation: Dense Stone"].it["Dense Stone"], 40,
    "a smaller later count does not erase the requirement");

-- The gate: no board, no capture.  This is what keeps ordinary NPC gossip out.
boardVisible = false;
ok (not Atr_CB_Harvest (), "harvest refuses when the board is not up");

-- Retention keeps a season and drops what falls out of it.
local db = Atr_CB_DB ();
db.weeks[wk - 40] = { first = 1, q = {} };
db.weeks[wk - 2]  = { first = 1, q = {} };
boardVisible = true;
db.weeks[wk] = nil;                      -- force the trim path by re-creating this week
Atr_CB_Harvest ();
ok (db.weeks[wk - 40] == nil, "a week beyond the window is dropped");
ok (db.weeks[wk - 2]  ~= nil, "a week inside the window is kept");

print (string.format ("%d passed, %d failed", pass, fail));
os.exit (fail == 0 and 0 or 1);
