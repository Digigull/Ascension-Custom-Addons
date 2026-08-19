-- FINDER: profession (trade skill) scanning ------------------------------------
--
-- This file owns everything the Finder learns from a profession window: the
-- crafted-goods recipe harvest, the recipe-tooltip fallback, and the per-item
-- craft-cost lookup the SELL tab's Crafted Goods Margin filter reads.  It was
-- lifted out of the main Auctionator.lua so the profession code lives in one
-- place -- both to keep the scan gentle (see the event frame at the bottom) and
-- to give future profession features (filter/sort the most profitable recipes)
-- a home to grow in.
--
-- The 3.3.5 client cannot be asked "what reagents craft item X"; that data is
-- only reachable while a profession window is open (GetTradeSkill* APIs).  So
-- we HARVEST it into AUCTIONATOR_CRAFT_RECIPES (account-wide) from two sources:
--
--   1. Profession windows (Atr_Craft_Harvest): every craftable item the player
--      can make.  Keyed by the produced item's ID, reagents by ID, with the
--      exact yield.  This is the reliable source.
--   2. Recipe ITEM tooltips (Atr_Craft_HarvestRecipeTooltip): when the player
--      views a plan/formula/recipe/pattern/schematic they haven't necessarily
--      learned, we read the created item from the recipe's name ("Pattern:
--      Frostweave Bag" -> "Frostweave Bag") and scrape the reagent line from
--      the tooltip.  Keyed by the created item's NAME, reagents by NAME, yield
--      assumed 1.  Best-effort (English tooltip format), fills coverage the
--      profession windows miss.
--
-- The Crafted Goods Margin filter then knows the craft cost of anything from
-- either source.  Coverage grows as professions are opened and recipes viewed.

local function Atr_Craft_DB()
    AUCTIONATOR_CRAFT_RECIPES = AUCTIONATOR_CRAFT_RECIPES or {};
    return AUCTIONATOR_CRAFT_RECIPES;
end

-- SHARED REAGENT PRICING -----------------------------------------------------
--
-- Reagent unit cost in copper, or nil when nothing can price it.
--
-- ONE cascade, used by every craft-cost path in this file: the harvested-recipe
-- cost (Atr_Craft_GetCraftCost) and the live trade-skill-window cost
-- (Atr_ProfSort_RowCost).  It used to be written out twice, once in each, with
-- a comment on the second saying it mirrored the first -- two copies of a
-- three-branch fallback that had to stay in agreement, or the Sell tab's
-- Crafted Goods Margin filter and the trade skill window's profit column would
-- quietly disagree about the same item.
--
-- The order is not arbitrary:
--   1. NPC price.  A vendor-sold reagent's real cost is the fixed shop price,
--      whatever someone is relisting it for on the auction house.
--   2. Auction price, by NAME.  The price DB is name-keyed, and a name still
--      works for a reagent whose item link came back nil -- which happens on
--      this client often enough that the harvest carries names for that reason.
--   3. Vendor sell value, as a rough floor, when nothing else knows it.
--
-- Step 2 asks by name in preference to ID, where the two earlier copies
-- disagreed (the harvested-recipe one asked by ID first).  Atr_GetAuctionPrice
-- resolves an ID to a name through GetItemInfo, so ID-first returns nothing for
-- an item the client has not cached while name-first still answers.  Same
-- result whenever both work; strictly better when only one does.
function Atr_Craft_ReagentPrice(id, name)
    local price = (id and Atr_GetNPCPrice) and tonumber(Atr_GetNPCPrice(id)) or nil;

    if (price == nil or price <= 0) then
        local key = name or id;
        price = (key and Atr_GetAuctionPrice) and tonumber(Atr_GetAuctionPrice(key)) or nil;
    end

    if (price == nil or price <= 0) then
        local key = id or name;   -- GetSellValue reads the item cache, so ID first here
        price = (key and Atr_GetSellValue) and tonumber(Atr_GetSellValue(key)) or nil;
    end

    if (price == nil or price <= 0) then return nil; end
    return price;
end

-- RECIPE YIELD ---------------------------------------------------------------

-- How many items one craft of trade skill row i produces.  The ONE place
-- GetTradeSkillNumMade is read, so the harvest, the live cost and the profit
-- sort can never disagree about a recipe's yield -- they each used to read it
-- for themselves.
--
-- The function returns minMade, maxMade.  We use minMade, deliberately: for a
-- variable-yield recipe (1-3 gems) costing at the low end overstates the
-- per-item cost, which is the safe direction to be wrong in.  On the recipe
-- that prompted the multi-output work -- Distilled Flask of the Unyielding --
-- the client reports min = max = 3, so the choice does not bite there;
-- /atrprofsort prints both returns so a row where it would can be spotted.
function Atr_Craft_RowYield(i)
    if (type(GetTradeSkillNumMade) ~= "function") then return 1; end
    local made = tonumber((GetTradeSkillNumMade(i))) or 1;   -- extra parens: minMade only
    if (made < 1) then made = 1; end
    return made;
end

-- WHAT A ROW IS SOLD AS ------------------------------------------------------

-- The item NAME a trade skill row's output is listed under, which is not always
-- the row's own name.  Three cases, and only the first is the row name itself:
--
--   ordinary craft   "Distilled Flask of the Unyielding" makes an item of the
--                    same name, so the row name works and always has.
--   TRANSMUTE        "Transmute: Arcanite" makes "Arcanite Bar".  The row is
--                    named for the ACTION, not the product, so looking the row
--                    name up on the auction house finds nothing -- no price, no
--                    profit, and the row sinks below every priced recipe in the
--                    sort.  Same failure the enchanting rows had, from the same
--                    cause: this file used to assume row name == product name.
--   ENCHANT          makes no item at all; sold as "Scroll of <row name>".
--
-- The produced item's own LINK is the authority here, and the row name is only
-- the fallback for a row this client hands back no link for.  This is the
-- named helper the enchanting work said would be wanted "for any craft whose
-- row name is not its product name" -- a transmute is exactly that craft.
-- Global for the harness.
function Atr_ProfSort_RowSellName(i)
    if (type(GetTradeSkillInfo) ~= "function") then return nil; end
    local rowName = (GetTradeSkillInfo(i));
    if (rowName == nil or rowName == "") then return nil; end

    if (Atr_ProfSort_RowIsEnchant(i)) then
        return Atr_Craft_ScrollName(rowName) or rowName;
    end

    local link = (type(GetTradeSkillItemLink) == "function") and GetTradeSkillItemLink(i) or nil;
    if (link and type(GetItemInfo) == "function") then
        local made = GetItemInfo(link);
        if (made and made ~= "") then return made; end
    end

    return rowName;
end

-- ENCHANTING -----------------------------------------------------------------
--
-- Enchanting is the one profession whose recipes produce no item, and that is
-- why every profit figure for it was blank rather than wrong.  A trade skill row
-- reads "Enchant Bracer - Superior Stamina" and GetTradeSkillItemLink hands back
-- an |Henchant: link, not an |Hitem: one, so the ID-keyed harvest skipped
-- enchanting entirely, and the profit column looked its market price up under
-- the ENCHANT's name -- which is never what is listed on the auction house.
--
-- What is actually sold is the enchant applied to an Enchanting Vellum: an
-- ordinary item called "Scroll of Enchant Bracer - Superior Stamina".  So an
-- enchant's economics are
--
--     cost  = reagents + one vellum
--     sells = auction price of  "Scroll of " .. <row name>
--
-- and both halves of that are handled here.
--
-- The vellum is bought from a vendor at a fixed price, which is exactly what the
-- NPC price learner already records (AuctionatorFinderMerchant.lua walks any
-- merchant window and stores unlimited-stock, gold-priced Trade Goods).  So
-- visiting any enchanting supplier prices it -- and prices it at what THIS
-- character actually pays, reputation discount included, which is the part a
-- hardcoded number could never get right.
--
-- THIS SERVER SPLITS THE VELLUM BY TARGET.  Retail 3.3.5 consolidated everything
-- into one "Enchanting Vellum" (item 38682) in patch 3.2, and assuming that here
-- was wrong: the owner's price database carries "Enchanting Vellum - Armor",
-- which means the pre-3.2 armor/weapon split is what Ascension actually ships.
-- Enchants are named "Enchant <Target> - <Effect>" -- observed targets are
-- Chest, Boots, Bracer, Gloves, Shield, Cloak, Weapon and 2H Weapon -- so the
-- target word chooses the vellum, and only the two Weapon ones take the weapon
-- vellum.
--
-- Vellums are therefore resolved by NAME, not by a hardcoded ID, with several
-- candidates tried in order so this survives a rename or a server that did
-- consolidate after all.  The ID needed for the NPC price lookup is recovered
-- from the item cache; when it cannot be, the auction price still answers.

ATR_ENCHANT_VELLUM_COLD = 24000;        -- 2g40s: owner's observed vendor price,
                                        -- 2026-08.  Last resort only -- superseded
                                        -- the moment any vellum can be priced.

-- Candidate item names per vellum kind, best first.  "Enchanting Vellum - Armor"
-- is confirmed present on Ascension; the rest are the retail names, kept so a
-- consolidated or renamed server still resolves.
ATR_ENCHANT_VELLUM_NAMES = {
    armor  = { "Enchanting Vellum - Armor",  "Armor Vellum III",  "Enchanting Vellum" },
    weapon = { "Enchanting Vellum - Weapon", "Weapon Vellum III", "Enchanting Vellum" },
};

ATR_SCROLL_PREFIX = "Scroll of ";       -- confirmed against the owner's price DB:
                                        -- 25 scrolls, every one "Scroll of <enchant>".

-- The item name an enchant is sold under.  Idempotent, so it is safe to call on
-- a name that is already a scroll.
function Atr_Craft_ScrollName(enchantName)
    if (type(enchantName) ~= "string" or enchantName == "") then return nil; end
    if (enchantName:sub(1, #ATR_SCROLL_PREFIX) == ATR_SCROLL_PREFIX) then return enchantName; end
    return ATR_SCROLL_PREFIX .. enchantName;
end

-- True for a trade skill link that makes an enchant rather than an item.  The
-- test is the link type itself, so the rows in an enchanting window that DO make
-- an item -- rods, shards, the odd oil -- return an item link, fail this, and
-- are costed as ordinary crafts.  Which is correct: those are sold as
-- themselves and consume no vellum.
function Atr_Craft_IsEnchantLink(link)
    return (type(link) == "string") and (link:find("|Henchant:", 1, true) ~= nil);
end

-- Whether trade skill row i makes an enchant.  Global for the harness.
function Atr_ProfSort_RowIsEnchant(i)
    if (type(GetTradeSkillItemLink) == "function") then
        local link = GetTradeSkillItemLink(i);
        if (link) then return Atr_Craft_IsEnchantLink(link); end
    end

    -- No link at all: the row is cold, or this client hands back nothing for an
    -- enchant.  Ask the price DB instead -- an enchant is precisely a row whose
    -- scroll exists as a real, priced item.  That is locale-proof (it does not
    -- test the profession's name) and self-consistent: a row we cannot find a
    -- scroll price for has no profit to report by either route.
    if (type(GetTradeSkillInfo) ~= "function") then return false; end
    local scroll = Atr_Craft_ScrollName((GetTradeSkillInfo(i)));
    if (scroll == nil or Atr_GetAuctionPrice == nil) then return false; end
    return (tonumber(Atr_GetAuctionPrice(scroll)) or 0) > 0;
end

-- Which vellum an enchant needs, from the target word in its name.  Anything
-- that is not a weapon takes the armor vellum, which is the safe default: armor
-- targets outnumber weapon ones heavily, and an unparsed name is far more likely
-- to be a new armor slot than a new weapon type.
function Atr_Craft_VellumKind(enchantName)
    if (type(enchantName) ~= "string") then return "armor"; end
    local target = enchantName:match("^Enchant%s+(.-)%s+%-");
    if (target and target:find("Weapon", 1, true)) then return "weapon"; end
    return "armor";
end

-- The item ID behind an item NAME, via the client's cache, or nil when it has
-- never been seen.  Only needed because NPC prices are ID-keyed while vellums
-- are identified here by name.
local function Atr_Craft_IDForName(name)
    if (type(name) ~= "string" or type(GetItemInfo) ~= "function") then return nil; end
    local _, link = GetItemInfo(name);
    if (link == nil or zc == nil or zc.ItemIDfromLink == nil) then return nil; end
    return tonumber((zc.ItemIDfromLink(link)));   -- extra parens: returns 3 values
end

-- What one vellum of the given kind costs, in copper.  Each candidate name goes
-- through the shared cascade, so a learned NPC price beats whatever someone is
-- relisting vellums for; the cold constant is only reached when none of the
-- names can be priced at all.
function Atr_Craft_VellumCost(kind)
    local names = ATR_ENCHANT_VELLUM_NAMES[kind or "armor"] or ATR_ENCHANT_VELLUM_NAMES.armor;
    for _, name in ipairs(names) do
        local p = Atr_Craft_ReagentPrice(Atr_Craft_IDForName(name), name);
        if (p and p > 0) then return p; end
    end
    return ATR_ENCHANT_VELLUM_COLD;
end

-- Walk the currently-open trade skill and store every recipe we can read.
-- Returns  stored, complete  where `complete` is false if any recipe row's item
-- link was still cold (data streaming in): the caller uses that to decide
-- whether this pass is final, so a cold-cache harvest is not mistaken for a
-- finished one and re-runs when the cache warms.
function Atr_Craft_Harvest()
    if (type(GetNumTradeSkills) ~= "function") then return 0, false; end
    local n = GetNumTradeSkills() or 0;
    if (n <= 0) then return 0, false; end

    local db = Atr_Craft_DB();
    local ItemID = (zc and zc.ItemIDfromLink) or nil;

    local stored, cold = 0, 0;
    for i = 1, n do
        local rowName, skillType = GetTradeSkillInfo(i);
        if (skillType and skillType ~= "header") then
            local madeLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i) or nil;
            if (madeLink == nil) then
                cold = cold + 1;   -- recipe row present but its item data is still streaming
            else
                -- Key by the produced item's ID, except for an enchant, which
                -- produces no item at all: those are keyed by the NAME of the
                -- scroll they are sold as, which the by-name lookup in
                -- Atr_Craft_GetCraftCost then finds unchanged.  isEnchant is
                -- carried into the record as the vellum KIND, so the cost path
                -- adds the right one without re-parsing the name.
                local madeID, isEnchant;
                if (Atr_Craft_IsEnchantLink(madeLink)) then
                    madeID    = Atr_Craft_ScrollName(rowName);
                    isEnchant = Atr_Craft_VellumKind(rowName);   -- armor / weapon
                else
                    madeID = ItemID and tonumber((ItemID(madeLink))) or nil;   -- extra parens: ItemID returns 3 values
                end
                if (madeID) then
                    local made = Atr_Craft_RowYield(i);

                    local reagents = {};
                    local numR = GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0;
                    for j = 1, numR do
                        local rname, _, rcount = GetTradeSkillReagentInfo(i, j);
                        local rlink = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, j) or nil;
                        local rid   = rlink and ItemID and tonumber((ItemID(rlink))) or nil;   -- extra parens: ItemID returns 3 values
                        -- Keep the reagent's NAME too, and store it even when only the
                        -- name is available: on the Ascension client
                        -- GetTradeSkillReagentItemLink can return nil while the name
                        -- (from GetTradeSkillReagentInfo) is fine.  Atr_Craft_GetCraftCost
                        -- prices by id OR name, so a name-only reagent still costs out --
                        -- without this the whole recipe was silently dropped.
                        if (rid or (rname and rname ~= "")) then
                            table.insert(reagents, { id = rid, name = rname, count = tonumber(rcount) or 1 });
                        end
                    end

                    if (#reagents > 0) then
                        db[madeID] = { made = made, reagents = reagents, vellum = isEnchant or nil };
                        stored = stored + 1;
                    end
                end
            end
        end
    end

    return stored, (cold == 0);
end

-- Per-item cost, in copper, to buy the reagents and craft the item, or nil when
-- it isn't a harvested recipe or a reagent price is missing.  Looks up the
-- recipe by produced-item ID (profession-window source) first, then by name
-- (recipe-tooltip source).  Reagent price is Auctionator's auction price (the
-- price DB is name-keyed, so ID- and name-based reagents both resolve); when a
-- reagent has no auction price (e.g. it is vendor-bought) we fall back to its
-- vendor value as a rough floor.  If even that is unavailable (item not cached)
-- the total is unknown, so we return nil and the caller leaves it unfiltered.
function Atr_Craft_GetCraftCost(link, name)
    if (AUCTIONATOR_CRAFT_RECIPES == nil) then return nil; end

    local rec;

    local itemID;
    if (type(link) == "number") then
        itemID = link;
    elseif (link and zc and zc.ItemIDfromLink) then
        itemID = tonumber((zc.ItemIDfromLink(link)));   -- extra parens: ItemIDfromLink returns 3 values
    end
    if (itemID) then rec = AUCTIONATOR_CRAFT_RECIPES[itemID]; end

    if (rec == nil) then
        if (name == nil and link and type(link) ~= "number" and GetItemInfo) then
            name = GetItemInfo(link);
        end
        if (name) then rec = AUCTIONATOR_CRAFT_RECIPES[name]; end
    end

    if (rec == nil or rec.reagents == nil) then return nil; end

    local total = 0;
    for _, r in ipairs(rec.reagents) do
        -- ID from the window harvest, name from the tooltip harvest; the shared
        -- cascade takes both and prefers whichever it can actually price.
        local price = Atr_Craft_ReagentPrice(r.id, r.name);
        if (price == nil) then
            return nil;   -- a reagent we can't price -> craft cost unknown
        end
        total = total + (price * (r.count or 1));
    end

    -- An enchant is only sellable once it has been applied to a vellum, so the
    -- vellum is as much a reagent as the dust is.  Which vellum is decided at
    -- harvest time from the enchant's target and stored on the record.
    if (rec.vellum) then
        total = total + Atr_Craft_VellumCost(rec.vellum);
    end

    -- The yield, and the one place it can be a guess.  A record harvested from
    -- a RECIPE ITEM's tooltip carries made = 1 by assumption, because a recipe
    -- tooltip never prints the yield (see Atr_Craft_HarvestRecipeTooltip).  For
    -- those records -- and only those -- ask the open profession window what
    -- the recipe really makes.  Without this, a multi-output craft whose recipe
    -- the player happened to hover reports the cost of a WHOLE craft against
    -- ONE item's sale price: precisely the mismatch multi-output recipes were
    -- reported with.  A window-harvested record read the real API and is left
    -- alone, and with no window open the live lookup returns nil, so the
    -- assumption simply stands as before.
    local made = rec.made or 1;
    if (rec.byTooltip) then
        local live = Atr_Craft_LiveYieldForItem(link, name);
        if (live) then made = live; end
    end
    if (made < 1) then made = 1; end

    -- Second return is the yield: a caller showing the figure to a human needs
    -- to be able to say "each" rather than leave per-item and per-craft numbers
    -- looking like they belong to the same craft.
    return math.floor(total / made), made;
end

-- True when we have a harvested recipe for this item at all, regardless of
-- whether its reagents can be priced.  Atr_Craft_GetCraftCost returns nil both
-- for "not a recipe" and for "a recipe with a reagent we can't price yet"; this
-- lets a caller (the craft-cost tooltip) tell those apart and show a "cost
-- unknown" hint for the craftable-but-unpriced case instead of staying silent.
function Atr_Craft_HasRecipe(link, name)
    if (AUCTIONATOR_CRAFT_RECIPES == nil) then return false; end

    local itemID;
    if (type(link) == "number") then
        itemID = link;
    elseif (link and zc and zc.ItemIDfromLink) then
        itemID = tonumber((zc.ItemIDfromLink(link)));   -- extra parens: returns 3 values
    end
    if (itemID and AUCTIONATOR_CRAFT_RECIPES[itemID]) then return true; end

    if (name == nil and link and type(link) ~= "number" and GetItemInfo) then
        name = GetItemInfo(link);
    end
    if (name and AUCTIONATOR_CRAFT_RECIPES[name]) then return true; end

    return false;
end

-- Split a tooltip line into reagent {name, count} pairs, or nil if the line is
-- not a reagent list.  Recipe tooltips end with a line like
-- "Frostweave Cloth (4), Infinite Dust (1)"; every comma-segment is
-- "<name> (<count>)".  The "Requires <Profession> (<skill>)" line also carries
-- a parenthesised number, so lines starting with "Requires"/"Use:" are rejected.
local function Atr_Craft_ParseReagentLine(text)
    if (type(text) ~= "string" or text == "") then return nil; end
    if (text:find("^Requires") or text:find("^Use:")) then return nil; end

    local reagents = {};
    for seg in string.gmatch(text .. ",", "%s*(.-)%s*,") do
        local rname, rcount = seg:match("^(.-)%s*%((%d+)%)$");
        if (not rname or rname == "") then return nil; end   -- a non-reagent segment: not a reagent line
        table.insert(reagents, { name = rname, count = tonumber(rcount) or 1 });
    end
    if (#reagents == 0) then return nil; end
    return reagents;
end

-- Harvest a recipe from the tooltip currently showing for a Recipe-class item.
-- `itemName` is the recipe item's name ("Pattern: Frostweave Bag"); the created
-- item's name is whatever follows the "<Prefix>: " (that is the item the player
-- would have in their bags).  The reagent list is scraped from the tooltip's
-- bottom line.  Yield is not shown on recipe tooltips, so it is assumed 1 --
-- for multi-yield recipes this overestimates per-item cost (holds more), which
-- is the safe direction.  Best-effort, English tooltip format.
function Atr_Craft_HarvestRecipeTooltip(tip, itemName)
    if (tip == nil or type(itemName) ~= "string") then return; end

    local created = itemName:match("^%a+:%s+(.+)$");   -- strip Plans:/Pattern:/Recipe:/Formula:/...
    if (created == nil or created == "") then return; end

    local getName = tip.GetName and tip:GetName() or nil;
    if (getName == nil) then return; end
    local n = (tip.NumLines and tip:NumLines()) or 0;

    local reagents;
    for i = 2, n do
        local fs = _G[getName .. "TextLeft" .. i];
        local txt = fs and fs.GetText and fs:GetText() or nil;
        local parsed = Atr_Craft_ParseReagentLine(txt);
        if (parsed) then reagents = parsed; end   -- keep the last match (reagents sit at the bottom)
    end

    if (reagents) then
        local db = Atr_Craft_DB();
        -- Don't shadow a precise profession-window entry: only the name key is
        -- written here, and the cost lookup prefers the ID key.
        db[created] = { made = 1, reagents = reagents, byTooltip = true };
    end
end

-- A stable fingerprint of the open profession: its name plus its recipe count.
-- Same profession, same count -> same list, so once it has been harvested with
-- a warm cache we never need to walk it again this session.  Learning a new
-- recipe changes the count and re-arms one harvest.  Returns nil when no
-- profession is really open (GetTradeSkillLine reports "UNKNOWN" then), which
-- keeps the throttle from ever skipping a genuine window.
local function Atr_Craft_Signature()
    if (type(GetTradeSkillLine) ~= "function") then return nil; end
    local prof = GetTradeSkillLine();
    if (prof == nil or prof == "" or prof == "UNKNOWN") then return nil; end
    local n = (type(GetNumTradeSkills) == "function") and (GetNumTradeSkills() or 0) or 0;
    if (n <= 0) then return nil; end
    return prof .. "#" .. n;
end

-- The guarded harvest the timer actually calls: skip entirely if this exact
-- profession list was already fully harvested this session, otherwise harvest
-- and record it -- but only mark it done when the cache was warm, so a harvest
-- taken mid-stream is retried on the next quiet update instead of locked in.
local function Atr_Craft_HarvestGuarded()
    local sig = Atr_Craft_Signature();
    if (sig and type(Fdr_ScanThrottle_Seen) == "function" and Fdr_ScanThrottle_Seen(sig)) then
        return;   -- already learned this profession this session
    end

    local ok, _, complete = pcall(Atr_Craft_Harvest);   -- best-effort: a harvest error must never break the UI
    if (ok and complete and sig and type(Fdr_ScanThrottle_Mark) == "function") then
        Fdr_ScanThrottle_Mark(sig);
    end
end

-- Harvest whenever a profession window opens or refreshes.  A dedicated frame
-- keeps this off the core event dispatcher.
--
-- TRADE_SKILL_UPDATE does NOT fire once per open: Blizzard's own UI refires it
-- for every recipe whose item data is still streaming in from the server, so a
-- single profession-window open produces a BURST of the event -- a full storm
-- when the item cache is cold (e.g. right after a client repair wipes it).
-- Re-harvesting the entire skill list on every one of those events froze the
-- client on large Ascension professions.  So we DEBOUNCE: each event just arms
-- a short timer, and the harvest runs ONCE, a beat after the updates go quiet.
-- On top of that the harvest is GUARDED by the session throttle, so re-opening
-- a profession already learned this session costs only a signature compare, not
-- another walk.  The produced-item IDs come straight from the recipe links, so
-- one late pass reads exactly the same data the per-event passes would have.
if (type(CreateFrame) == "function") then
    local f = CreateFrame("Frame");
    f:RegisterEvent("TRADE_SKILL_SHOW");
    f:RegisterEvent("TRADE_SKILL_UPDATE");

    local DELAY   = 0.5;     -- seconds of quiet before harvesting
    local elapsed = 0;

    f:Hide();                -- OnUpdate only ticks while shown; stay idle until armed

    f:SetScript("OnEvent", function(self)
        elapsed = 0;
        self:Show();         -- (re)arm the timer; a fresh event pushes it back out
    end);

    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (dt or 0);
        if (elapsed >= DELAY) then
            elapsed = 0;
            self:Hide();     -- stop ticking before harvesting (idempotent, one-shot)
            Atr_Craft_HarvestGuarded();
        end
    end);
end

-- PROFITABILITY SORT: "Sort by Profit" checkbox on the profession window ------
--
-- A checkbox that sits just above the trade-skill window's top-left corner.
-- When ticked, the recipe list is reordered so the items you can craft at the
-- biggest profit sit at the top and the least profitable (or loss-making) sit
-- at the bottom.  Recipes we cannot fully price (a reagent with no known cost,
-- or a produced item with no auction price) sink below every priced recipe,
-- keeping the ranked part of the list trustworthy.
--
-- It composes WITH the window's built-in controls, not instead of them: the
-- subclass / slot dropdowns, the "Have Materials" checkbox and the search box
-- all narrow what GetTradeSkillInfo returns, and we simply re-rank whatever
-- survives those filters.  Category headers are dropped while sorting (a flat
-- ranked list is the whole point), so turning the box on expands every
-- collapsed category first, so nothing hides from the ranking.
--
-- How the reorder works without fighting Blizzard's (skinned) UI: we do NOT
-- rebuild the window.  TradeSkillFrame_Update is wrapped so the ORIGINAL runs
-- first (it styles the rows, updates the rank bar, the reagent panel, the
-- create button -- everything), and then, only while the box is ticked, we
-- rewrite just the visible list buttons to point at our ranked order.  Each
-- button keeps a REAL trade-skill index as its ID, so clicking, selecting,
-- the detail pane and Create all keep working through stock code untouched.
-- The whole rewrite is pcall-guarded: any surprise on this custom client
-- disables the feature and falls straight back to the stock list rather than
-- leaving a broken window.
--
-- Profit per CRAFT = (the produced item's auction price, Atr_GetAuctionPrice,
-- minus its per-item reagent cost) times the recipe's yield.  One craft is what
-- the ranking compares, because one craft is what a press of Create costs you
-- and earns you; a recipe making 3 at 12g each beats one making 1 at 20g.  The
-- row is marked "(total)" whenever the recipe makes more than one, so the
-- figure is never mistaken for a per-item one.  Reagent cost goes through
-- Atr_Craft_ReagentPrice at the top of this file -- the one cascade the Crafted
-- Goods Margin filter uses too, so the two never drift apart.
--
-- Two rows do not fit that sentence and are handled where it says so above:
--   * An ENCHANT has no produced item, so its market price is looked up under
--     the scroll it is sold as, and the vellum it is applied to is added to the
--     cost.  See the ENCHANTING block at the top of this file.
--   * A recipe whose yield the client misreports is costed per item from
--     whatever GetTradeSkillNumMade says; `/atrprofsort <name>` prints both of
--     that function's returns so a suspect row can be checked against reality.

-- Per-item craft COST for trade-skill row i, in copper, or nil when a reagent
-- can't be priced.  Read live from the open window, and independent of the
-- produced item's own market price, so the craft-cost tooltip can show a cost
-- even for an item that has never been on the AH.
--
-- Returns  cost, made  -- the cost is PER ITEM (the reagent total divided by the
-- yield) and `made` is that yield, so a caller rendering the number for a human
-- can label which of the two scales it is on.  Global for the harness.
function Atr_ProfSort_RowCost(i)
    if (type(GetTradeSkillInfo) ~= "function") then return nil; end
    local _, skillType = GetTradeSkillInfo(i);
    if (skillType == "header") then return nil; end

    local made = Atr_Craft_RowYield(i);

    local numR = (type(GetTradeSkillNumReagents) == "function") and (GetTradeSkillNumReagents(i) or 0) or 0;
    if (numR == 0) then return nil; end

    local total = 0;
    for j = 1, numR do
        local rname, _, rcount = GetTradeSkillReagentInfo(i, j);
        local rlink = (type(GetTradeSkillReagentItemLink) == "function") and GetTradeSkillReagentItemLink(i, j) or nil;
        local rid   = (rlink and zc and zc.ItemIDfromLink) and tonumber((zc.ItemIDfromLink(rlink))) or nil;   -- extra parens: returns 3 values
        local price = Atr_Craft_ReagentPrice(rid, rname);
        if (price == nil) then return nil; end   -- one unpriceable reagent -> whole recipe unpriced
        total = total + price * (tonumber(rcount) or 1);
    end

    -- The vellum an enchant has to be applied to before it can be sold; armor
    -- and weapon vellums are different items at different prices.
    if (Atr_ProfSort_RowIsEnchant(i)) then
        total = total + Atr_Craft_VellumCost(Atr_Craft_VellumKind((GetTradeSkillInfo(i))));
    end

    return math.floor(total / made), made;
end

-- Per-item craft profit for trade-skill row i, in copper, or nil when it can't
-- be totalled (not a real recipe, unpriced produced item, or any reagent we
-- can't price).  Returns  profit, cost, sell, made  -- the first three PER ITEM
-- and `made` the recipe's yield, so a caller can present per-craft figures
-- without reading the yield a second time and risking a different answer.
-- Global so the mock-WoW harness can unit-test the maths without a real window.
function Atr_ProfSort_RowProfit(i)
    if (type(GetTradeSkillInfo) ~= "function") then return nil; end
    local name, skillType = GetTradeSkillInfo(i);
    if (skillType == "header" or name == nil) then return nil; end

    -- A row is not always listed under its own name: an enchant sells as a
    -- scroll, a transmute is named for the action rather than the product.
    -- Looking the row name up directly is what left every enchanting row -- and
    -- then every transmute -- unpriced, and therefore sorted below every other
    -- recipe with a blank profit column.  Atr_ProfSort_RowSellName knows all
    -- three cases; see it for which.
    local sellName = Atr_ProfSort_RowSellName(i) or name;

    local sell = (Atr_GetAuctionPrice) and tonumber(Atr_GetAuctionPrice(sellName)) or nil;
    if (sell == nil or sell <= 0) then return nil; end   -- no market price to rank on

    local cost, made = Atr_ProfSort_RowCost(i);
    if (cost == nil) then return nil; end

    return (sell - cost), cost, sell, (made or 1);
end

-- The index of the row in the OPEN profession window that makes this item, or
-- nil when no window is open or nothing in it makes the item.  Split out of
-- Atr_Craft_LiveCostForItem because the yield is wanted from the same row and
-- by the same three-way match; two copies of the match would be two chances to
-- answer differently for the same item.  Global for the harness.
function Atr_Craft_FindRowForItem(link, name)
    if (type(GetNumTradeSkills) ~= "function") then return nil; end
    local n = GetNumTradeSkills() or 0;
    if (n <= 0) then return nil; end

    local wantID;
    if (type(link) == "number") then
        wantID = link;
    elseif (link and zc and zc.ItemIDfromLink) then
        wantID = tonumber((zc.ItemIDfromLink(link)));
    end
    if (name == nil and link and type(link) ~= "number" and GetItemInfo) then
        name = GetItemInfo(link);
    end

    for i = 1, n do
        local madeName, skillType = GetTradeSkillInfo(i);
        if (skillType and skillType ~= "header") then
            local matched = false;
            if (wantID and type(GetTradeSkillItemLink) == "function") then
                local madeLink = GetTradeSkillItemLink(i);
                local madeID = (madeLink and zc and zc.ItemIDfromLink) and tonumber((zc.ItemIDfromLink(madeLink))) or nil;
                if (madeID and madeID == wantID) then matched = true; end
            end
            if (not matched and name and madeName == name) then matched = true; end
            -- "Scroll of Enchant X" on the auction house is made by the row
            -- called "Enchant X", so the craft-cost tooltip finds it too.
            if (not matched and name and madeName and Atr_Craft_ScrollName(madeName) == name) then
                matched = true;
            end
            if (matched) then return i; end
        end
    end
    return nil;
end

-- Craft cost for a produced item, read LIVE from the open profession window by
-- matching the item to the recipe that makes it.  Returns  cost, found, made
-- where found is true when a matching recipe row exists at all (so the tooltip
-- can say "cost unknown" rather than nothing when the row is there but a
-- reagent isn't priced) and made is that recipe's yield.  This is the reliable
-- path on the Ascension client, where the background harvest into
-- AUCTIONATOR_CRAFT_RECIPES can miss recipes whose reagent item links come back
-- nil.  Global for the harness.
function Atr_Craft_LiveCostForItem(link, name)
    local i = Atr_Craft_FindRowForItem(link, name);
    if (i == nil) then return nil, false; end

    local cost, made = Atr_ProfSort_RowCost(i);   -- cost may be nil (a reagent unpriced), but the recipe exists
    return cost, true, (made or Atr_Craft_RowYield(i));
end

-- How many items one craft of this item's recipe makes, read live from the open
-- profession window, or nil when no open row makes it.  The authority a stored
-- record's ASSUMED yield defers to (see Atr_Craft_GetCraftCost).  Global for the
-- harness.
function Atr_Craft_LiveYieldForItem(link, name)
    local i = Atr_Craft_FindRowForItem(link, name);
    if (i == nil) then return nil; end
    return Atr_Craft_RowYield(i);
end

-- Walk the open trade skill and return  order, profitByIndex, madeByIndex where
-- order is a list of REAL skill indices (headers dropped) ranked
-- profit-descending, profitByIndex maps each of those indices to its profit
-- (nil = unpriceable) and madeByIndex to the recipe's yield.  Priced recipes
-- rank above every unpriceable one; ties and unpriceable rows keep their
-- original list order (a stable sort).  Global for the harness.
--
-- THE PROFIT HERE IS PER CRAFT, NOT PER ITEM.  That is the figure one press of
-- Create actually earns, and it is the only one that ranks two recipes fairly
-- against each other: a flask that makes 3 at 12g each beats a potion that
-- makes 1 at 20g, because the same single craft, off one set of reagents, is
-- worth 36g rather than 20g.  Ranking on the per-item figure quietly answered a
-- different question, and -- with nothing on the row saying which scale it was
-- on -- read as the row disagreeing with itself on a multi-output recipe.
-- Atr_ProfSort_RowProfit still returns per-item figures; the multiply is here,
-- where the ranking decision lives.
function Atr_ProfSort_BuildOrder()
    local n = (type(GetNumTradeSkills) == "function") and (GetNumTradeSkills() or 0) or 0;
    local entries, profitByIndex, madeByIndex = {}, {}, {};
    for i = 1, n do
        local _, skillType = GetTradeSkillInfo(i);
        if (skillType and skillType ~= "header") then
            local p, _, _, made = Atr_ProfSort_RowProfit(i);
            made = made or 1;
            if (p ~= nil) then p = p * made; end
            profitByIndex[i] = p;
            madeByIndex[i]   = made;
            entries[#entries + 1] = { index = i, profit = p, seq = #entries + 1 };
        end
    end

    table.sort(entries, function(a, b)
        if (a.profit == nil and b.profit == nil) then return a.seq < b.seq; end
        if (a.profit == nil) then return false; end   -- unpriceable sinks below anything priced
        if (b.profit == nil) then return true; end
        if (a.profit ~= b.profit) then return a.profit > b.profit; end   -- most profit first
        return a.seq < b.seq;   -- stable tie-break
    end);

    local order = {};
    for k, e in ipairs(entries) do order[k] = e.index; end
    return order, profitByIndex, madeByIndex;
end

-- Compact signed copper -> short coloured string ("+12g" / "-3s" / "+40c").
-- Only the largest non-zero denomination is shown so the row stays short.
local function Atr_ProfSort_MoneyShort(c)
    local neg = (c < 0);
    local a   = neg and -c or c;
    local g   = math.floor(a / 10000);
    local s   = math.floor((a % 10000) / 100);
    local str;
    if     (g > 0) then str = g .. "g";
    elseif (s > 0) then str = s .. "s";
    else                str = a .. "c"; end
    local col = neg and "|cffff5555" or "|cff55ff55";
    return col .. (neg and "-" or "+") .. str .. "|r";
end

-- Full copper -> "12g 34s 56c" for diagnostics, or "(nil)" when unpriced.
-- Distinct from Atr_ProfSort_MoneyShort above, which deliberately keeps only the
-- largest denomination so a list row stays narrow; a diagnostic wants the lot.
function Atr_ProfSort_Money(c)
    c = tonumber(c);
    if (c == nil) then return "(nil)"; end
    local neg = (c < 0);
    local a   = neg and -c or c;
    return (neg and "-" or "")
        .. math.floor(a / 10000) .. "g "
        .. math.floor((a % 10000) / 100) .. "s "
        .. (a % 100) .. "c";
end

-- ---- reorder state + UI ----------------------------------------------------

local Atr_ProfSort_OrigUpdate;                 -- saved stock TradeSkillFrame_Update
local gProfSort_Check;                          -- the checkbox frame
local gProfSort_Broken   = false;               -- a render error disables us for the session
local gProfSort_Order    = nil;                 -- cached ranked index list
local gProfSort_Profit   = nil;                 -- cached index -> PER-CRAFT profit map
local gProfSort_Made     = nil;                 -- cached index -> recipe yield
local gProfSort_Sig      = nil;                 -- signature the cache was built for
local gProfSort_InRemap  = false;               -- guards our own remap against re-entry
local gProfSort_Suspend  = false;               -- true while expanding categories: skip the sort pass
local gProfSort_HiTex    = nil;                  -- our own faint selection texture
Atr_ProfSort_LastError   = nil;                 -- last remap error, for /atrprofsort diagnostics

-- Our own selection highlight: a faint, transparent bar we fully control, drawn
-- in the BACKGROUND layer so it sits BEHIND the row text.  We use this instead
-- of moving the stock TradeSkillHighlightFrame -- reparenting/resizing that
-- shared frame leaked into (and broke) the normal, sort-off highlight.  Created
-- lazily on the frame that owns the list button it will sit over.
local function Atr_ProfSort_HiTexFor(btn)
    if (btn == nil or type(btn.CreateTexture) ~= "function") then return nil; end
    if (gProfSort_HiTex == nil) then
        gProfSort_HiTex = btn:CreateTexture(nil, "BACKGROUND");
        gProfSort_HiTex:SetTexture(1, 0.82, 0, 0.16);   -- faint gold, mostly transparent
    end
    return gProfSort_HiTex;
end

local function Atr_ProfSort_Enabled()
    return (AUCTIONATOR_FINDER_SETTINGS ~= nil) and (AUCTIONATOR_FINDER_SETTINGS.profSort == true);
end

-- A cheap fingerprint of the current (filtered) list.  Same profession, same
-- count and same first/last row name -> same list, so scrolling reuses the
-- ranked order and only a real filter/list change rebuilds it.
local function Atr_ProfSort_Signature()
    if (type(GetNumTradeSkills) ~= "function") then return "0"; end
    local n     = GetNumTradeSkills() or 0;
    local prof  = (type(GetTradeSkillLine) == "function" and GetTradeSkillLine()) or "?";
    local first = (n > 0) and select(1, GetTradeSkillInfo(1)) or "";
    local last  = (n > 0) and select(1, GetTradeSkillInfo(n)) or "";
    return prof .. "#" .. n .. "#" .. tostring(first) .. "#" .. tostring(last);
end

-- Rewrite the visible list buttons to our ranked order.  Called only while the
-- box is ticked, always after the stock update has run.  Errors here are
-- caught by the wrapper, which then falls back to the stock list.
local function Atr_ProfSort_Remap()
    local scroll = TradeSkillListScrollFrame;
    if (scroll == nil) then return; end

    local DISPLAYED = (type(TRADE_SKILLS_DISPLAYED) == "number" and TRADE_SKILLS_DISPLAYED) or 8;
    local HEIGHT    = (type(TRADE_SKILL_HEIGHT)    == "number" and TRADE_SKILL_HEIGHT)    or 16;

    local sig = Atr_ProfSort_Signature();
    if (sig ~= gProfSort_Sig or gProfSort_Order == nil) then
        gProfSort_Order, gProfSort_Profit, gProfSort_Made = Atr_ProfSort_BuildOrder();
        gProfSort_Sig = sig;
    end
    local order   = gProfSort_Order or {};
    local numRows = #order;

    local offset = FauxScrollFrame_GetOffset(scroll) or 0;
    local maxOff = numRows - DISPLAYED;
    if (maxOff < 0) then maxOff = 0; end
    if (offset > maxOff) then offset = maxOff; end

    local selected = TradeSkillFrame and TradeSkillFrame.selectedSkill;
    local selectedBtn = nil;   -- the visible button showing the selected recipe, if any

    for i = 1, DISPLAYED do
        local btn = _G["TradeSkillSkill" .. i];
        if (btn) then
            local pos = offset + i;
            if (pos <= numRows) then
                local realIndex = order[pos];
                local name, skillType, numAvailable = GetTradeSkillInfo(realIndex);
                local base = name or "?";
                if (numAvailable and numAvailable > 0) then base = base .. " [" .. numAvailable .. "]"; end

                -- Colour by difficulty via an escape code baked into the text, NOT
                -- SetTextColor: the Ascension list buttons have SetText but no
                -- SetTextColor method (calling it errored and disabled the sort).
                local color = (type(TradeSkillTypeColor) == "table") and TradeSkillTypeColor[skillType] or nil;
                local hex = color and string.format("%02x%02x%02x",
                    math.floor((color.r or 1) * 255 + 0.5),
                    math.floor((color.g or 1) * 255 + 0.5),
                    math.floor((color.b or 1) * 255 + 0.5)) or "ffffff";
                local shown = "|cff" .. hex .. base .. "|r";

                -- The profit is for ONE CRAFT (see Atr_ProfSort_BuildOrder).  A
                -- recipe that makes more than one says so against the figure, so
                -- a row can never be read as a per-item number when it is not
                -- one -- the mismatch that made multi-output recipes look wrong
                -- on both this list and the tooltip.
                --
                -- The marker is "(total)", not the yield.  "+31g x3" reads as an
                -- instruction to multiply -- three times 31g -- when the figure
                -- is ALREADY the whole craft (owner, 2026-08-19).  It is
                -- deliberately appended with no space, so that when the row runs
                -- out of width it is the marker that gets clipped rather than
                -- the digits.  The tooltip has room to name the yield and still
                -- says "x3"; a list row does not.
                local profit = gProfSort_Profit and gProfSort_Profit[realIndex];
                if (profit ~= nil) then
                    shown = shown .. "  " .. Atr_ProfSort_MoneyShort(profit);
                    local made = gProfSort_Made and gProfSort_Made[realIndex];
                    if (made and made > 1) then shown = shown .. "|cff8888ff(total)|r"; end
                end

                btn:SetText(shown);

                if (btn.SetID) then btn:SetID(realIndex); end   -- stock click/selection reads GetID(): keep it real
                btn:Show();

                if (selected == realIndex) then selectedBtn = btn; end
                if (btn.UnlockHighlight) then btn:UnlockHighlight(); end   -- clear any stray mouse-over lock
            else
                btn:Hide();
            end
        end
    end

    -- The stock TradeSkillHighlightFrame anchors itself by the recipe's NATURAL
    -- position, so once we reorder it points at the wrong (usually scrolled-away)
    -- row.  We do NOT touch its parent or points (doing so leaked into the normal
    -- sort-off highlight) -- we only HIDE it while sorting, and draw our own faint
    -- bar on the correct row instead.  Stock re-shows it when the sort is off.
    if (TradeSkillHighlightFrame and TradeSkillHighlightFrame.Hide) then
        TradeSkillHighlightFrame:Hide();
    end

    local hi = Atr_ProfSort_HiTexFor(selectedBtn);
    if (hi) then
        if (selectedBtn) then
            hi:SetParent(selectedBtn);
            hi:ClearAllPoints();
            hi:SetPoint("TOPLEFT",     selectedBtn, "TOPLEFT",     0, 0);
            hi:SetPoint("BOTTOMRIGHT", selectedBtn, "BOTTOMRIGHT", 0, 0);
            hi:Show();
        else
            hi:Hide();
        end
    end

    FauxScrollFrame_Update(scroll, numRows, DISPLAYED, HEIGHT);   -- range = ranked count, not the stock total
end

-- Expand every collapsed category so no recipe hides from the ranking.  Only
-- called from the checkbox click (a safe context) and window-open, never from
-- inside the remap.  Suspended so the burst of updates the expands trigger just
-- redraw the stock list; the single ranked pass runs afterwards, from Refresh.
local function Atr_ProfSort_ExpandAll()
    if (type(GetNumTradeSkills) ~= "function" or type(ExpandTradeSkillSubClass) ~= "function") then return; end
    gProfSort_Suspend = true;
    pcall(function()
        local n = GetNumTradeSkills() or 0;
        for i = n, 1, -1 do   -- bottom-up: expanding header i only inserts rows after i
            local _, skillType, _, isExpanded = GetTradeSkillInfo(i);
            if (skillType == "header" and not isExpanded) then
                ExpandTradeSkillSubClass(i);
            end
        end
    end);
    gProfSort_Suspend = false;
end

-- TradeSkillFrame_Update wrapper: stock first (styles rows + the rest of the
-- window), then our ranked rewrite of the list when the box is ticked.
--
-- Two guards keep it safe.  gProfSort_InRemap makes a nested call a complete
-- no-op: our own FauxScrollFrame_Update can move the scrollbar, and SetValue
-- fires the scroll handler SYNCHRONOUSLY, which re-enters TradeSkillFrame_Update
-- mid-remap -- letting it run again would re-stock the rows we just sorted (or
-- recurse without end).  gProfSort_Suspend lets the stock update run but skips
-- the sort pass while we are expanding categories.
local function Atr_ProfSort_Wrapper(...)
    if (gProfSort_InRemap) then return; end   -- re-entry from our own scroll update: do nothing
    if (Atr_ProfSort_OrigUpdate) then Atr_ProfSort_OrigUpdate(...); end
    if (gProfSort_Suspend) then return; end
    if (Atr_ProfSort_Enabled() and not gProfSort_Broken) then
        gProfSort_InRemap = true;
        local ok, err = pcall(Atr_ProfSort_Remap);
        gProfSort_InRemap = false;
        if (not ok) then
            gProfSort_Broken = true;
            Atr_ProfSort_LastError = tostring(err);
            if (AUCTIONATOR_FINDER_SETTINGS) then AUCTIONATOR_FINDER_SETTINGS.profSort = false; end
            if (gProfSort_Check) then gProfSort_Check:SetChecked(nil); end
            if (gProfSort_HiTex) then gProfSort_HiTex:Hide(); end               -- drop our selection bar
            if (Atr_ProfSort_OrigUpdate) then Atr_ProfSort_OrigUpdate(); end   -- redraw a clean stock list
            if (DEFAULT_CHAT_FRAME) then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Auctionator:|r Sort by Profit hit a snag and was turned off: |cffff8888"
                    .. tostring(err) .. "|r  (type /atrprofsort to copy this)");
            end
        end
    end
end

local function Atr_ProfSort_InstallHook()
    if (Atr_ProfSort_OrigUpdate) then return; end                 -- already installed
    if (type(TradeSkillFrame_Update) ~= "function") then return; end
    Atr_ProfSort_OrigUpdate = TradeSkillFrame_Update;
    TradeSkillFrame_Update  = Atr_ProfSort_Wrapper;
end

-- Re-rank and redraw now (e.g. right after the box is clicked).
local function Atr_ProfSort_Refresh()
    gProfSort_Order, gProfSort_Profit, gProfSort_Made, gProfSort_Sig = nil, nil, nil, nil;   -- force a rebuild
    if (type(TradeSkillFrame_Update) == "function") then TradeSkillFrame_Update(); end
end

local function Atr_ProfSort_CreateCheckbox()
    if (gProfSort_Check) then return; end
    if (type(CreateFrame) ~= "function" or TradeSkillFrame == nil) then return; end   -- retry on the next open

    local chk = CreateFrame("CheckButton", "Atr_ProfSort_Check", TradeSkillFrame, "UICheckButtonTemplate");
    chk:SetWidth(20);
    chk:SetHeight(20);
    -- Up in the title bar, in the gap between the portrait and the centred
    -- profession title.  A small box + short label so it fits that strip.
    chk:SetPoint("TOPLEFT", TradeSkillFrame, "TOPLEFT", 76, -15);

    local label = _G["Atr_ProfSort_CheckText"];
    if (label) then
        label:SetText("Sort Profit");
        if (GameFontHighlightSmall) then label:SetFontObject(GameFontHighlightSmall); end   -- compact, fits the title strip
    end

    AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
    chk:SetChecked(AUCTIONATOR_FINDER_SETTINGS.profSort and true or nil);

    chk:SetScript("OnClick", function(self)
        AUCTIONATOR_FINDER_SETTINGS = AUCTIONATOR_FINDER_SETTINGS or {};
        local on = self:GetChecked() and true or false;
        AUCTIONATOR_FINDER_SETTINGS.profSort = on;
        gProfSort_Broken = false;                       -- a re-tick clears a prior snag and retries
        if (on) then
            Atr_ProfSort_ExpandAll();
        elseif (gProfSort_HiTex) then
            gProfSort_HiTex:Hide();                     -- our bar must not linger once the sort is off
        end
        Atr_ProfSort_Refresh();
    end);

    chk:SetScript("OnEnter", function(self)
        if (GameTooltip == nil) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:AddLine("Sort by Profit");
        GameTooltip:AddLine("Ranks the recipes you can make most profitable first,", 1, 1, 1, true);
        GameTooltip:AddLine("least profitable last. The window's own filters still apply.", 1, 1, 1, true);
        GameTooltip:AddLine("Profit = the item's auction price minus its reagent cost.", 0.7, 0.7, 0.7, true);
        GameTooltip:Show();
    end);
    chk:SetScript("OnLeave", function() if (GameTooltip) then GameTooltip:Hide(); end end);

    gProfSort_Check = chk;
    Atr_ProfSort_InstallHook();
end

-- Build the checkbox the first time a profession window opens (TradeSkillFrame
-- is real by then), and force a fresh ranking for the newly-opened list.
if (type(CreateFrame) == "function") then
    local cf = CreateFrame("Frame");
    cf:RegisterEvent("TRADE_SKILL_SHOW");
    cf:SetScript("OnEvent", function()
        Atr_ProfSort_CreateCheckbox();
        gProfSort_Order, gProfSort_Profit, gProfSort_Made, gProfSort_Sig = nil, nil, nil, nil;   -- new window -> rebuild
        if (Atr_ProfSort_Enabled() and not gProfSort_Broken) then Atr_ProfSort_ExpandAll(); end
    end);
end

-- /atrprofsort [text] : diagnostics for the profit sort.  Prints what the
-- reorder can see on this client (the frame, scroll frame and list buttons it
-- needs), the feature's state and the last error -- so a "hit a snag" report has
-- something concrete behind it.  Copies to the clipboard when the client
-- supports it.
--
-- With `text`, it also dumps the working per-row figures for every open recipe
-- whose name contains it, which is how the two things this file gets asked about
-- are actually checked:
--
--   /atrprofsort distilled     -- what GetTradeSkillNumMade really returns for a
--                                 multi-output recipe.  BOTH returns are shown,
--                                 because the cost maths reads only the first
--                                 (minMade) and the open question is whether the
--                                 second differs.
--   /atrprofsort stamina       -- whether an enchant is recognised as one, and
--                                 which item name its market price came from.
if (SlashCmdList) then
    SLASH_ATRPROFSORT1 = "/atrprofsort";
    SlashCmdList["ATRPROFSORT"] = function (msg)
        local L = {};
        local function add(s) L[#L + 1] = s; end

        local btns = 0;
        while (_G["TradeSkillSkill" .. (btns + 1)]) do btns = btns + 1; end

        local open  = (type(GetNumTradeSkills) == "function") and (GetNumTradeSkills() or 0) or 0;
        local order = (open > 0) and select(1, Atr_ProfSort_BuildOrder()) or {};
        local _, profByIdx = Atr_ProfSort_BuildOrder();
        local priced = 0;
        if (profByIdx) then for _, p in pairs(profByIdx) do if (p ~= nil) then priced = priced + 1; end end end

        add("Auctionator Sort by Profit -- diagnostics");
        add("  TradeSkillFrame:        " .. (TradeSkillFrame and "present" or "MISSING"));
        add("  TradeSkillFrame_Update: " .. (type(TradeSkillFrame_Update) == "function" and "present" or "MISSING"));
        add("  hook installed:         " .. (Atr_ProfSort_OrigUpdate and "yes" or "no"));
        add("  TradeSkillListScrollFrame: " .. (TradeSkillListScrollFrame and "present" or "MISSING"));
        add("  list buttons found:     " .. btns .. " (TradeSkillSkill1..N)");
        add("  TRADE_SKILLS_DISPLAYED: " .. tostring(TRADE_SKILLS_DISPLAYED));
        add("  FauxScrollFrame_Update: " .. (type(FauxScrollFrame_Update) == "function" and "present" or "MISSING"));
        add("  setting (profSort):     " .. tostring(AUCTIONATOR_FINDER_SETTINGS and AUCTIONATOR_FINDER_SETTINGS.profSort));
        add("  disabled by error:      " .. (gProfSort_Broken and "yes" or "no"));
        add("  open profession rows:   " .. open .. "  (recipes ranked: " .. #order .. ", priced: " .. priced .. ")");
        add("  last error:             " .. (Atr_ProfSort_LastError or "(none)"));

        -- Vellums: what an enchant's mandatory extra reagent costs, per kind, and
        -- which candidate name actually answered.  A kind with no name priced is
        -- running on the cold-start constant and says so.
        for _, kind in ipairs({ "armor", "weapon" }) do
            local via;
            for _, nm in ipairs(ATR_ENCHANT_VELLUM_NAMES[kind]) do
                if (Atr_Craft_ReagentPrice(nil, nm)) then via = nm; break; end
            end
            add("  vellum (" .. kind .. "):" .. string.rep(" ", 10 - string.len(kind))
                .. Atr_ProfSort_Money(Atr_Craft_VellumCost(kind))
                .. (via and ("  via " .. via)
                        or  "  (NOTHING PRICED - using the cold-start constant)"));
        end

        -- Per-row detail for a name filter.
        local filter = tostring(msg or ""):gsub("^%s+", ""):gsub("%s+$", "");
        if (filter ~= "" and open > 0) then
            local want, shown = filter:lower(), 0;
            add("");
            add("  rows matching \"" .. filter .. "\":");
            for i = 1, open do
                local rname, skillType = GetTradeSkillInfo(i);
                if (rname and skillType and skillType ~= "header" and rname:lower():find(want, 1, true)) then
                    shown = shown + 1;

                    local lo, hi;
                    if (type(GetTradeSkillNumMade) == "function") then lo, hi = GetTradeSkillNumMade(i); end

                    local isEnch   = Atr_ProfSort_RowIsEnchant(i);
                    local sellName = Atr_ProfSort_RowSellName(i) or rname;
                    local sell     = Atr_GetAuctionPrice and tonumber(Atr_GetAuctionPrice(sellName)) or nil;
                    local cost     = Atr_ProfSort_RowCost(i);
                    local profit   = Atr_ProfSort_RowProfit(i);
                    local made     = Atr_Craft_RowYield(i);

                    -- The produced item's LINK is the datum most of this file
                    -- keys off -- the harvest skips a row without one, and the
                    -- item-to-row match behind the craft-cost tooltip needs it
                    -- for any row whose name is not its product's.  When
                    -- something is wrong for one profession and right for the
                    -- rest, this line is usually where it shows.
                    local madeLink = (type(GetTradeSkillItemLink) == "function") and GetTradeSkillItemLink(i) or nil;

                    add("    [" .. i .. "] " .. rname .. (isEnch and "   (enchant)" or ""));
                    add("        NumMade:  min=" .. tostring(lo) .. "  max=" .. tostring(hi)
                        .. "   (cost maths uses min)");
                    add("        made link: " .. (madeLink and madeLink:gsub("|", "||") or "(NONE - harvest skips this row)"));
                    add("        sells as: " .. sellName);
                    add("        per item:    sell=" .. Atr_ProfSort_Money(sell)
                        .. "  cost=" .. Atr_ProfSort_Money(cost)
                        .. "  profit=" .. Atr_ProfSort_Money(profit));
                    -- BOTH scales, always, each labelled.  Printing one set of
                    -- figures next to a yield left the reader to work out which
                    -- scale they were on -- the whole multi-output confusion in
                    -- a single line.  When the yield is 1 the two lines agree,
                    -- which costs one line and settles the question outright.
                    add("        per craft x" .. made .. ": sell="
                        .. Atr_ProfSort_Money(sell and (sell * made) or nil)
                        .. "  cost=" .. Atr_ProfSort_Money(cost and (cost * made) or nil)
                        .. "  profit=" .. Atr_ProfSort_Money(profit and (profit * made) or nil)
                        .. "   <- what the list ranks on");
                end
            end
            if (shown == 0) then add("    (no open recipe matched)"); end
        end

        local report = table.concat(L, "\n");
        if (DEFAULT_CHAT_FRAME) then
            for _, line in ipairs(L) do DEFAULT_CHAT_FRAME:AddMessage(line); end
        end
        if (type(CopyToClipboard) == "function") then
            CopyToClipboard(report);
            if (DEFAULT_CHAT_FRAME) then DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00(copied to clipboard)|r"); end
        end
    end
end
-- PROFITABILITY SORT end -----------------------------------------------------
