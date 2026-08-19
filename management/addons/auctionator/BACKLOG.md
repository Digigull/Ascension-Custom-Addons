# Auctionator — request backlog

Owner's request list, recorded 2026-08-19 before any work starts. This file is the queue and
the record of what each item actually means against the code as it stands; it is not a design
doc. When an item is built, its findings go in a proper per-topic doc (the way
`VENDOR-PRICE-RESEARCH.md` did) and the row here shrinks to a link.

Items marked **DONE** have shipped; the rest have not been implemented. **Nothing here has
been tested in game** — every "current behaviour" note is read from source, not observed, and
a shipped item's own section says what was and was not verified.

Anchors are `file:line` at the time of writing and will drift; the symbol names next to them
are the durable part.

---

## 1. SELL tab — drop the header icon, keep the title, move the hover — DONE

**Asked:** on the Sell tab remove the top icon, keep the title, and make hover-over possible
on the sell item.

**What is there now.** The header strip of the expanded SELL layout is two rows. Row 1 is
`Atr_RecommendItem_Tex` (a 37px `Button`, `Auctionator.xml:768`) parked at panel TOPLEFT
`(6, -37)` by `Atr_ApplySellExpandedLayout` (`Auctionator.lua:2587`), with the item's name
beside it at `(48, -48)` — that name is the "title", written by `Atr_Sell_SetHeaderName`
(`Auctionator.lua:2335`), quality-coloured and chopped to `ATR_SELL_NAME_W` (215px).

The hover currently lives **on the icon only**: the button's `OnEnter`/`OnLeave` call
`Atr_ShowRecTooltip` / `Atr_HideRecTooltip` (`Auctionator.lua:3732`), which anchor
`GameTooltip` to `Atr_RecommendItem_Tex` and `SetHyperlink(link, num)` for the current stack
size.

**So the work is:** hide the icon, re-anchor the title into the space it vacates, and give the
title string a hover of its own.

Two things to be careful of:

- The tooltip owner is the icon frame. If the icon is hidden but kept as the owner, the
  tooltip anchors to a hidden frame; the new owner should be whatever the pointer is actually
  over.
- A `FontString` cannot take `OnEnter`. The title needs an invisible `Frame`/`Button` sized to
  the *measured* string (`GetStringWidth`, after `Atr_Sell_SetHeaderName` has chopped it) sat
  on top of it, re-sized every time the name changes.
- `Atr_RecommendItem_Tex` is also touched by `Atr_SetTextureButton`
  (`Auctionator.lua:3229`, `:3605`, `:4235`) and is element 7 of `recommendElements`
  (`Auctionator.lua:869`), which shows/hides the whole recommend block. Hiding the icon has to
  survive those paths re-showing it — the block is shown wholesale after a post.
- It is in `ATR_SELL_GEOM` (`Auctionator.lua:2263`), so the reset path restores its position.
  Hiding, not moving, keeps that honest.

**Open:** the drop zone (`Atr_Sell_DropZoneEnsure`, `Auctionator.lua:2443`) is a *separate*
37px target in the left column and is not what this item is about. Leave it.

**Revised on sight of it (owner, 2026-08-19).** The first cut hid the icon and moved the
hover onto the name where the icon had been. Seeing it in game, the owner asked for the header
band cleared outright instead: the item name goes into the left column, in the slot the
"Drop an item here to sell" caption held; that caption drops to under the box; the hover moves
to **the drop box**, so the tooltip is on the item you are actually selling; and the recommended
price rows go with the icon. That is what is built.

**Built.** All in `Auctionator.lua`; the XML is untouched.

- **`Atr_Sell_HeaderApply`** (next to `Atr_Sell_SetHeaderName`) hides everything in
  `ATR_SELL_HEADER_HIDDEN`: the icon, the "based on" note, and both recommended-price rows with
  their captions. Hiding is **re-applied, not done once** — every one of those is a member of
  `recommendElements`, which `Atr_ShowElems` shows wholesale after a post, and the icon is
  additionally re-shown by `Atr_SetTextureButton`. So it is called from every path that rewrites
  the header, and always *after* those calls.
- **They stay in `recommendElements`.** `Atr_HideElems` is what hides them in the first place —
  including the unconditional one on every tab switch — and nothing in the XML marks them hidden
  at load. Dropping them from the table would leave them shown for one frame after login.
- **The header is shared with the BUY tab**, where the icon still draws the searched item, so
  `Atr_Sell_HeaderApply` is a no-op unless `Atr_IsTabSelected(SELL_TAB)`.
- **The name moves into the column**, `TOP` of `Atr_SellControls` at `ATR_SELL_TITLE_Y`. It is a
  region of `Atr_Main_Panel` anchored to a child frame, which is legal and needs no reparenting:
  `Atr_SellControls` paints nothing, so there is no layer for it to disappear behind. It is in
  `ATR_SELL_GEOM`, so leaving the tab puts it back in the header for BUY.
- **`ATR_SELL_NAME_W` drops 215 → 160.** The budget is now the 170px column, not the header
  strip, so it matches `ATR_SELL_HINT_W` for the same reason. Names chop harder than they did;
  the full one is on the tooltip.
- **The caption moves under the box**, anchored to the box's `BOTTOM` rather than to a column
  offset, so it follows if the box moves.
- **The price block below had to drop 8px** to clear it. `ATR_SELL_PRICE_Y` (-90, was -82 in the
  XML) is now the origin every row under it is measured from — the `-94 / -128 / -140` and
  `-162 / -124` literals were exactly these offsets from -82, so parameterising them changed
  nothing and then moved the whole block at once. `Atr_StackPriceText` and `Atr_ItemPriceText`
  are positioned from Lua for the first time, which is why they had to join `ATR_SELL_GEOM`.
- **The tooltip is wired onto `Atr_SellControls_Tex`** from the layout, not the XML — the button
  is shared with the panel's other tabs, the same reason the rest of this layout is built in
  Lua. Nothing is clobbered: the XML gives that button `OnClick` and the two drag handlers, no
  hover. An empty box shows nothing, since `Atr_ShowRecTooltip` has no link to open.
- **`Atr_ShowRecTooltip` resolves its owner per call**, not once: `Atr_Idle` re-runs it every
  frame while the tooltip is up, and `SetOwner` on a hidden frame anchors nothing. It picks the
  drop box when that is *visible* — `IsVisible`, not `IsShown`, because a shown child of a
  hidden parent still reports `IsShown` — and the header icon otherwise.

**Left alone deliberately:** the emptied header band is *not* closed up. Raising the inventory
into it would move the results block and the Current/Ledger tabs with it, which is a separate
decision; `ATR_SELL_HB_Y` / `ATR_SELL_SF_Y` are where that would be tuned.

**Verified** by `luac5.1 -p` and by reading every path that shows the icon, the price rows or the
header name. **Not verified in-game** — the vertical arithmetic in the left column is the part
to look at first: the caption now sits between the box and the "Buyout Price" label with 8px of
clearance, computed from assumed `GameFontNormalSmall` metrics rather than measured.

---

## 2. Enchanting profit is missing on the trade skill window — DONE

**Asked:** enchanting profit on the tradeskill window is not working.

**Cause, confirmed by the owner.** Enchanting is the one profession whose recipes produce no
item. The trade skill row is named for the *enchant* ("Enchant Bracer - Superior Stamina") and
`GetTradeSkillItemLink` returns an `|Henchant:` link, not an `|Hitem:` one. So the ID-keyed
harvest skipped enchanting entirely, and the profit column looked the market price up under the
enchant's name — which is never what is listed. Every enchanting row came back unpriced, which
is why the symptom was a *blank* column rather than a wrong number.

**The economics, per the owner.** An enchant is sold by applying it to an **Enchanting Vellum**,
producing an ordinary item called "Scroll of Enchant Bracer - Superior Stamina". The vellum is
vendor-bought at a fixed price (observed 2g40s, and subject to a reputation discount). So:

```
cost  = reagents + one vellum
sells = auction price of  "Scroll of " .. <row name>
```

**Built.** All in `AuctionatorFinderProfession.lua`:

- `Atr_Craft_IsEnchantLink` / `Atr_ProfSort_RowIsEnchant` — an enchant is identified by its
  *link type*, so the rows in an enchanting window that do make real items (rods, shards) still
  cost as ordinary crafts and get no vellum added. When the client returns no link at all, the
  fallback asks whether a scroll by that name is a priced item — locale-proof, and it cannot
  claim an enchant we could not have priced anyway.
- `Atr_Craft_ScrollName` — the enchant-to-scroll name mapping, used by the profit lookup, the
  harvest key, and the tooltip's reverse match.
- `Atr_Craft_VellumCost` — the vellum priced through the shared cascade. **The vendor price is
  learned, not hardcoded:** `AuctionatorFinderMerchant.lua` already records unlimited-stock,
  gold-priced Trade Goods from any merchant window, so visiting an enchanting supplier prices
  the vellum at what *that character* pays, reputation discount included.
  `ATR_ENCHANT_VELLUM_COLD` (2g40s) is only the cold-start value before any such vendor is seen.
- The harvest now stores enchant recipes keyed by scroll name with a `vellum` flag, so the Sell
  tab's Crafted Goods Margin filter and the craft-cost tooltip cover scrolls too.

**Verified** against a mock trade skill window under bare `lua5.1`: cost, profit, the rod
exclusion, the harvest key and flag, the tooltip's reverse lookup, and the ranking. **Not
verified in-game.**

**Confirmed by the owner's price database, 2026-08-19.** The dump settles both halves of the
mapping, and corrects an assumption that would otherwise have shipped wrong:

- **Scroll naming is exactly `"Scroll of " .. <enchant name>`** — 25 scrolls in the dump, every
  one of that form (`Scroll of Enchant Weapon - Lesser Striking`, `Scroll of Enchant Bracer -
  Lesser Strength`, …). The mapping is safe to build on.
- **The vellum is NOT one item here.** The dump carries **`Enchanting Vellum - Armor`**, which
  means this server keeps the *pre-3.2* armor/weapon vellum split rather than the single
  consolidated "Enchanting Vellum" (38682) that retail 3.3.5 uses. So a fix that adds one
  hardcoded vellum would be wrong for every weapon enchant.
- **The target word picks the vellum.** Enchants are named `Enchant <Target> - <Effect>`;
  targets observed in the dump are Chest, Boots, Bracer, Gloves, Shield, Cloak, Weapon and
  2H Weapon. Only the two Weapon variants take the weapon vellum. Armor is the right default
  for an unparsed name — a new armor slot is far likelier than a new weapon type.

**Fix shape.** A named helper both `RowProfit` and the harvest use, rather than a
`string.format` at the call site — the same mismatch returns for any craft whose row name is
not its product name. Resolve vellums **by name** with several candidates tried in order, not
by a hardcoded ID: the ID that the NPC price lookup needs can be recovered from the item cache,
and where it cannot be, the auction price still answers. Enchant recipes should be harvested
under the scroll's name so the Sell tab's margin filter and the craft-cost tooltip cover
scrolls too.

**Still unverified:** the *vendor* price of each vellum, which needs an enchanting supplier to
have been opened so the NPC price learner records it. Until then the observed 2g40s stands as
a cold-start constant.

**What to check when testing.** `/atrprofsort <text>` prints, per matching row: whether the row
is recognised as an enchant, which item name its market price came from, both returns of
`GetTradeSkillNumMade`, and the cost/sell/profit derived. It also prints each vellum kind with
the candidate name that priced it, or says the cold-start constant is in use. Two things to
confirm there:

1. That **both** vellum kinds price from a real name. `Enchanting Vellum - Armor` is confirmed
   present; `Enchanting Vellum - Weapon` is inferred from the split and has not been seen. If
   the weapon line reports the cold-start constant after visiting an enchanting supplier, the
   weapon vellum has a different name and the candidate list wants that name adding.
2. That the vellum prices come from a **vendor**, not the auction house. Opening any enchanting
   supplier is what makes that happen.


**Follow-up shipped 2026-08-19: the figures now appear on the enchant's tooltip.** The profit
sort had been ranking enchanting rows correctly for a while, but hovering the row still showed
`Auction unknown` and no craft lines at all — `ShowTipWithPricing` is built entirely on
`GetItemInfo`, which returns nothing for an `|Henchant:` link, so there was never an item for
it to talk about. `Atr_AddEnchantTradeSkillTip` (`AuctionatorHints.lua`) now handles an
enchanting recipe hover from the trade skill *index* instead, and the `SetTradeSkillItem` hook
diverts to it, skipping the item path entirely rather than leaving its `Auction unknown` line
above a real scroll price. It prints the scroll it is sold as, the scroll's auction price and
median, the craft cost (labelled `(+vellum)`, since the vellum is in the total but not in the
window's reagent list) and the profit. Reagent hovers are never diverted. Same ALT gate and
same `AUCTIONATOR_A_TIPS` gate as every other addon price line. **Not verified in game.**

---

## 3. Multi-output crafts price wrong (Distilled Flasks makes 3) — DONE

**Asked, twice in the list:** some crafts produce multiple items — Distilled Flasks makes 3
per craft — and profit is off. If the yield can't be recognised reliably, let the user type a
per-craft yield on the trade skill window, defaulting to 1.

**The diagnostic has now been read in game (owner, 2026-08-19), and it is outcome 1.**
`/atrprofsort distilled` reported:

```
[43] Distilled Flask of the Unyielding
     NumMade:  min=3  max=3   (cost maths uses min)
     sells as: Distilled Flask of the Unyielding
     sell=47g69s96c  cost=30g51s99c  profit=17g17s97c   (all per item)
```

So `GetTradeSkillNumMade` **does** report the yield on this client, both returns agree, and the
arithmetic already divided by it — 30g51s99c is the reagent total (91g55s97c) over 3. The
manual per-recipe yield box is therefore **not needed and was not built**; item 3's fallback
plan is retired rather than deferred.

**What was actually wrong was that nothing said which scale a figure was on**, and two places
picked different scales:

- The **tooltip** put a per-*item* craft cost directly under a per-*item* Auction price with no
  label on either, so the pair could equally be read as one flask's sale price against a whole
  craft's cost — which is how it was read, and it is not a misreading the reader can settle
  from the tooltip.
- The **profit sort** ranked on per-item profit. That silently answers a different question
  from the one the list is for: one press of Create consumes one set of reagents, so a recipe
  making 3 at 12g each earns 36g where one making 1 at 20g earns 20g. Ranked per item the
  flask lost to the potion.

**Built.**

- `Atr_Craft_RowYield(i)` (`AuctionatorFinderProfession.lua`) — the single read of
  `GetTradeSkillNumMade`. The harvest, the live cost and the profit sort each had their own
  copy; three copies of a clamp are three chances to answer differently for one recipe. Still
  `minMade`, deliberately (see the comment there); `/atrprofsort` still prints both returns.
- The yield is now **carried, not re-derived**: `Atr_Craft_GetCraftCost` returns `cost, made`,
  `Atr_ProfSort_RowCost` returns `cost, made`, `Atr_ProfSort_RowProfit` returns
  `profit, cost, sell, made`, and `Atr_Craft_LiveCostForItem` returns `cost, found, made`.
- `Atr_Craft_FindRowForItem(link, name)` split out of `Atr_Craft_LiveCostForItem`, with
  `Atr_Craft_LiveYieldForItem` on top of it — the item→row match is wanted for the yield too
  and should not exist twice.
- **The tooltip shows the PER-CRAFT figures, tagged with the yield**, when the yield is above
  1: `Craft cost x3` / `Craft profit x3`. A yield of 1 is unchanged. Under the Shift stack
  multiplier the yield multiply stands down — every line is already scaled by the hovered
  stack and says so through `xstring`, and two multipliers on one tooltip is the same
  ambiguity again.

  **This shipped first as both scales side by side** — `(each)` and `x3` — which was correct
  and was clutter. The owner asked for the per-item pair to go (2026-08-19): one craft is what
  a press of Create costs and earns, it is what the profit sort ranks on, and the tag is what
  keeps it honest against the per-item Auction line above it. Both figures remain a function
  call apart if the question ever comes back — `Atr_Craft_GetCraftCost` and
  `Atr_ProfSort_RowCost` still return per-item costs with the yield beside them, and
  `/atrprofsort` still prints both scales.
- **The profit sort ranks per craft**, and marks a multi-output row `(total)` against the
  figure (`+36g(total)`) so a row can never be read as a per-item number when it is not one.
  `Atr_ProfSort_BuildOrder`'s `profitByIndex` is now per-craft; `Atr_ProfSort_RowProfit` still
  returns per-item, and the multiply lives where the ranking decision lives.

  The marker started as the yield (`+36g x3`) and was changed on the owner's report
  (2026-08-19): next to a money figure `x3` reads as *multiply this by three*, which is exactly
  backwards — the figure is already the whole craft. No space before it, deliberately, so a row
  too narrow for both clips the marker rather than the digits.
- **An assumed yield now defers to a known one.** `Atr_Craft_HarvestRecipeTooltip` stores
  `made = 1` because a recipe *item*'s tooltip never prints the yield. That record is keyed by
  name, so for a multi-output craft whose recipe the player happened to hover it reported a
  whole craft's cost against one item's sale price — the reported symptom exactly, reachable
  without any client bug at all. `Atr_Craft_GetCraftCost` now asks the open profession window
  for the real yield when, and only when, the record's own yield is that assumption.
- `/atrprofsort <text>` prints **both** scales per row, labelled, and marks which one the list
  ranks on.

**Verified** under bare `lua5.1` against a mock trade skill window: the yield reaching every
consumer, per-item vs per-craft agreeing to a factor of the yield, the enchant row still
costing with its vellum at yield 1, the ranking putting the multi-output row first, and the
assumed-yield record deferring to the live window (and standing when no window is open).
**Not verified in game.**

**Still open, and cheap to settle:** whether 30g51s99c per flask is *right*, i.e. whether the
reagent prices behind it are. Outcome 1 said the maths is right and any remaining error is in
a reagent price or the produced item's own auction price; nothing above tests that. The new
`per craft x3` line makes it checkable at a glance — 91g55s97c of reagents against a 127g80s
stack of 3 on the AH.

---

## 4. Finder — stats dropdown usable before a search has run

**Asked:** on the Finder page have the stats dropdown available before seeing them in results.

**Current behaviour.** `gFdr_StatKeys` (`AuctionatorFinder.lua:114`) is rebuilt from the
*results* of the last scan (`:2693`) — the keys are whatever `GetItemStats` reported on the
gear that came back, minus any stat present with an identical value on every single result
(the `ubiquitousConstant` filter, `:2695`). `Fdr_StatDD_Initialize` (`:3808`) lists exactly
that table, so before the first search the dropdown is `(clear all)` and nothing else.

This is a real ordering problem for the user: the stats are a *filter*
(`Fdr_PassesStatFilter`, `:741` — a selected stat that a row lacks removes the row), so the
natural flow is pick the stat, then search. Today you must search, then pick, then look again.

**Decided (owner, 2026-08-19): learn, don't seed.** No static `ITEM_MOD_*` list. The addon
remembers every stat key it has ever seen on gear and offers the accumulated set in the
dropdown from then on, so the list is empty on a fresh install and fills in as you search. That
sidesteps the two problems a static seed had — a long list of stock keys that may not apply on
this server, and Ascension's custom stats, which no stock constant covers and which a static
list would have had to fall back to discovery for anyway.

**Learn from the RAW discoveries, not from `gFdr_StatKeys`.** This is the part that is easy to
get wrong. `statSeen` (`AuctionatorFinder.lua:2607`) accumulates every stat key on every
equippable result. `gFdr_StatKeys` is what survives *two* filters applied to it (`:2694`):

- `FDR_DPS_KEY` is dropped because DPS has its own dedicated column.
- `ubiquitousConstant` drops a stat that appears on **every** result with an **identical**
  value, on the grounds that it cannot discriminate between them.

The second is a judgement about *this result set only*. A search narrow enough that every hit
carries the same +10 Stamina drops Stamina — and Stamina is obviously worth remembering.
Persisting the post-filter list would make what gets learned depend on the shape of your past
searches, and a stat could end up harder to learn precisely because you once searched for it
too precisely. So: **learn from `statSeen`'s keys, and keep `ubiquitousConstant` as a display
rule for the current results only.** `FDR_DPS_KEY` should stay out of the learned set too, for
the same reason it is excluded now.

**Storage.** `AUCTIONATOR_FINDER_SETTINGS` is already an account-wide SavedVariable (declared
in the `.toc`), so a `statKeys` sub-table lands there with no `.toc` change. Account-wide is
right — stats are a property of the server's items, not of a character. The set is bounded by
the number of distinct stat keys that exist, so no pruning rule is needed; a sanity cap that
complains rather than silently truncating is cheap insurance against a malformed key being
written in a loop.

**Display.** `Fdr_StatDisplayName` (`:178`) already handles unknown keys — it reads `_G[key]`
and falls back to de-tokenising the key itself — so a learned custom stat gets a readable label
with no extra mapping.

Two ordering choices worth making deliberately:

- List the stats present in the current results first, then the rest of the learned set. Before
  a search there is only the learned set, which is the whole point of the item.
- Dim the learned-but-not-in-these-results entries. Selecting one *is* meaningful before a
  search, but after a search it will empty the list — `Fdr_PassesStatFilter` (`:741`) removes
  any row missing a selected stat. Dimming makes that predictable rather than surprising.

The selection already survives a stat vanishing from results — the comment at `:2704` says so
deliberately — so pre-selecting before a scan needs nothing extra to persist.

The dropdown rebuilds through `UIDropDownMenu_Initialize` every time it opens, so it picks up a
grown set with no refresh plumbing.

---

## 5. Finder — "My iLvL" should not default on — DONE

**Asked:** remove "My iLvL" as a default check.

**Resolved (owner, 2026-08-19): this is the `My Lvl` checkbox.** There is no checkbox labelled
"My iLvL" — the wording in the request is the label read loosely. The Finder
has two that auto-tick themselves whenever the selected categories include gear, in
`Fdr_AutoFillMinLevel` (`AuctionatorFinder.lua:3558`):

- **`Usable`** (`Atr_Finder_UsableCheck`, `:3941`)
- **`My Lvl`** (`Atr_Finder_ReqCheck`, `:3948`) — hides items whose *required level* is above
  your character's level; persisted as `AUCTIONATOR_FINDER_SETTINGS.reqOnly`

Both use the same etiquette: auto-tick once, and if the user unticks it, never auto-tick again
that session (`gFdr_AutoUsable`/`gFdr_UsableUserOff`, `gFdr_AutoReq`/`gFdr_ReqUserOff`).
There is also a **Lvl** *column* and an **iLvl** *column* (`:4210`), and the same function
auto-fills the minimum level box with `UnitLevel("player") - 5` (`:3612`) — which is the only
other thing in the Finder that defaults itself from the character.

**The work:** drop `Atr_Finder_ReqCheck` out of the auto-tick block in `Fdr_AutoFillMinLevel`,
leaving the checkbox available to tick manually. `Usable` and the auto-filled minimum level box
keep their current behaviour — the owner asked for neither.

Its `gFdr_AutoReq` / `gFdr_ReqUserOff` pair exists only to serve the auto-tick, and
`AUCTIONATOR_FINDER_SETTINGS.reqOnly` is written from inside that block. Removing the auto-tick
means the persisted setting has to be honoured from wherever the user's own click lands, or the
checkbox will forget itself between sessions.

**Built.** The `My Lvl` block is out of `Fdr_AutoFillMinLevel`, and `gFdr_AutoReq` /
`gFdr_ReqUserOff` are gone with it — they existed only to remember an override of an auto-tick
that no longer happens. `Usable` and the auto-filled minimum level box are untouched.

**The persisted setting needed no new plumbing**, which is worth recording because the item
above flagged it as the risk. `reqOnly` was already written by the checkbox's own `OnClick`
(`AuctionatorFinder.lua:3954`) and already read back at creation
(`reqchk:SetChecked (AUCTIONATOR_FINDER_SETTINGS.reqOnly …)`, `:3951`) — the auto-tick's writes
were a *third* writer layered on top. Removing them leaves one writer and one reader, so the
checkbox now remembers exactly the user's own last click. `Atr_Finder_ClearFilters` still
clears it, which is correct: Clear Filters is a user action.

The comment left in place says the auto-tick was removed on request and that nothing in that
function may write `reqOnly` — the failure mode if it is ever re-added is silent, and it
overwrites a saved choice the user did make.

**Verified** by `luac5.1 -p` and by grepping that no reference to either removed global
survives. **Not verified in-game.**

---

## 6. Finder — filter recipes by already-learned

**Asked:** if searching recipes on the Finder, have a filter for already learned.

**Nothing exists.** The Finder has no notion of recipes at all — no `IsRecipe`, no known-spell
check anywhere in `AuctionatorFinder.lua`.

**The mechanism that will work on 3.3.5.** For a recipe *item*, the tooltip carries the red
`"Already known"` line (`ITEM_SPELL_KNOWN`) when the character has learned it. Reading it
means scanning the item's tooltip, which is the same technique the Finder's full scan already
uses to read a listing's true item level and DPS (`AuctionatorFinder.lua:1265` and the
Hints file's tooltip scraper, `AuctionatorHints.lua:880`). So the tooling exists; this is a
new consumer of it, not new machinery.

Watch for:

- The check is **per character**, unlike almost everything else Auctionator persists
  account-wide. The cache has to be keyed by character or it will lie on an alt.
- `Atr_Craft_HarvestRecipeTooltip` (`AuctionatorFinderProfession.lua:198`) already parses recipe
  item tooltips for reagents and already strips the `Pattern:`/`Formula:`/`Plans:` name prefix (`:201`).
  Read the known-line in the same pass rather than scanning twice.
- Ascension's tooltip strings may not match the stock English `ITEM_SPELL_KNOWN`. Verify.

Ships as a checkbox next to `Usable`/`My Lvl`, active only when the results contain recipes.

---

## 7. NEW — Ledger: record all purchases and sales

**Asked:** a new ledger recording all purchases and sales.

**Naming, resolved (owner, 2026-08-19).** "Ledger" was already taken: tab 2 of `Atr_ListTabs`
(`Auctionator.xml:1004`), the *price-history* view of the currently-scanned item, rendered by
`Atr_ShowHistory` (`Auctionator.lua:4867`). It has nothing to do with the player's own
transactions.

**The existing tab is renamed to "History"** — which is what it actually shows; note
`Atr_ShowHistory` already sets its column heading to `ZT("History")` (`Auctionator.lua:4878`),
so the tab label was the odd one out. **"Ledger" is then free for the new transaction record.**

The rename touches the tab's `text` attribute in `Auctionator.xml:1004` and any localisation of
it; `Atr_ShowWhichRB(2)` and the `PanelTemplates_SetTab` calls key off the numeric id, not the
label, so nothing functional moves.

**What has to be captured.**

| Event | Hook |
|---|---|
| Bought at auction | `PlaceAuctionBid` is issued from `AuctionatorBuy.lua:296`; the addon drives the whole multi-buy loop itself, so it knows the item, stack and price it *intended* to pay |
| Sold at auction | `CHAT_MSG_SYSTEM` auction-sold message, and/or the mail from the AH |
| Auction expired / cancelled | the same mail path; needed or the books never balance |
| Deposit paid | known at post time on the Sell tab |
| Vendor buy/sell | `MERCHANT_SHOW` + bag deltas — `AuctionatorFinderMerchant.lua` already sits on the merchant window |

**Do the buy side first and do it honestly.** The buy loop knows what it *asked* for; what
actually *arrived* is a different question, and item 9 below is exactly that question. So the
ledger should record the intended purchase **and** the delivered item where they can be
distinguished, not assume they match. That is what makes item 9 answerable rather than a
second guess.

### The row is the design decision

Everything else about the Ledger is ordinary; the row shape is the part that is expensive to
change later, because a row written under the wrong schema cannot be back-filled. Four things
have to be decided before the first row is written, and the reasoning for each:

**1. Intended vs. delivered are separate fields, not one.** The buy loop knows what it *asked*
for; what arrived is a different question and is exactly what item 9 is about. A row that
records only "bought X" cannot answer it. Record both, and leave the delivered side nil when we
genuinely could not observe it — nil is honest, a copy of the intended value is not.

**2. Money is copper, always.** The Bazaar already established this ("everything is reduced to
copper internally, since that's the only exact integer axis the AH gives us" — `README.md`).
Store unit price *and* quantity separately rather than a total, since every downstream question
— per-item margin, restock cost — needs the unit.

**3. Time needs a real timestamp, not a display string.** `AUCTIONATOR_PRICING_HISTORY` packs
its time through `ToTightTime` (`Auctionator.lua:6221`) to keep the table small. Reuse that if
size matters, but keep the *resolution*: the Advisor (item 8) is the only consumer that will
ever need a series out of this, and it will want ordering finer than the day.

**4. Rows carry a source tag.** Auction buy, auction sale, expiry, cancellation, deposit,
vendor buy, vendor sale — one table with a `src` field, not seven tables. The Ledger's whole
value is being able to total across them.

**Storage:** a new account-wide saved variable with a bounded row count. The Hints DB caps its
raw sample log at 500 (`AuctionatorHints.lua:901`) — follow that precedent, but note the Ledger
is a *record* rather than a sample, so pruning loses history the user may care about. Prefer a
generous cap plus a documented pruning rule (oldest first) over silent eviction, and never the
mean DB's random eviction (`FRAMEWORK.md` §5 — it destroyed the ordering there and cannot be
undone). Decide the cap before writing rows, not after the file gets large.

**Scope question still open:** whether the first version covers vendor buy/sell and mail, or
auction house activity only. That is the difference between one event source and five, and it
decides whether the Ledger ships in one pass or two.

This item is the prerequisite for items 8 and 9. Build it first.

---

## 8. NEW — Advisor

**Asked:** "Ore is up go mine, crafting profit good make this..."

**Deliberately underspecified, and that is fine for now.** Everything an advisor needs is
already computed somewhere: `Atr_ProfSort_BuildOrder`
(`AuctionatorFinderProfession.lua:436`) already ranks every recipe you can make by profit;
the price DB has history; the Bazaar knows vendor stock. What is missing is (a) a *trend* —
"ore is up" needs a price yesterday to compare against, and (b) a place to say it.

**The gate on this one is data, not UI.** Price history exists per scan, but the addon does
not currently keep a dated series per item that would let it say "up 30% this week". Confirm
what `AUCTIONATOR_PRICE_DATABASE` actually retains before designing anything — if it keeps
only a current price, the advisor cannot exist until it keeps a series, and the Ledger (item
7) is the natural place for that plumbing to land.

Scope this properly with the owner once the Ledger is in. Do not start it before then.

---

## 9. BUY tab — bought a Grovewood Log, received a Grovewood Plank (parked)

**Asked:** explicitly parked — revisit after the Ledger exists, because the Ledger will make
it diagnosable.

**Why this is plausible and worth keeping.** `AuctionatorFinderBuyRedirect.lua:29-35` already
documents the underlying hazard in this codebase's own words: the Buy tab condenses a scan by
item **name** and keeps essentially one item link per name, so on a server that scales item
instances invisibly to the link, "a purchase can deliver a different item than the one
displayed". The whole Finder tab exists because of it. That mechanism is about *scaled
variants of the same item*, though — Log vs Plank are two different items with different
names, so if the report is accurate it is either a different bug or a server-side conversion,
not this one.

**Agreed plan: do nothing until item 7 lands**, then read the ledger's intended-vs-delivered
columns for a real case. Recorded here only so the observation is not lost.

---

---

## 10. NEW — the price database on one realm is in a format this addon cannot read

**Found while reading the owner's dump, 2026-08-19.** Not reported by the owner; surfaced by
the data. Recorded because it may invalidate every price-dependent feature on the affected
realm, which would include the enchanting work above.

The supplied `AUCTIONATOR_PRICE_DATABASE` holds four realm keys, in **two different shapes**:

| Realm key | Entries | Shape |
|---|---:|---|
| `Rexxar - Conquest of Azeroth_Alliance` | 53 | plain numbers |
| `Rexxar - Conquest of Azeroth` | 16 | plain numbers |
| `Bronzebeard - Warcraft Reborn_Alliance` | 178 tables + 3 plain | `{ mr, id, cc, sc, lastScan, H<day>, L<day> }` |
| `Bronzebeard - Warcraft Reborn` | 347 tables | `{ mr, po, lastScan, H<day> }` |

**This addon reads and writes plain numbers only.** Every access is
`gAtr_ScanDB[name]` treated as a number — `AuctionatorHints.lua:287`, `AuctionatorScan.lua:668`,
`AuctionatorFinderPriceDB.lua:165`, and the rest. Nothing anywhere reads `mr`, `id`, `cc`, `sc`
or the `H<day>`/`L<day>` keys. So on the Bronzebeard realms `Atr_GetAuctionPrice` returns a
**table**, every `tonumber()` on it yields nil, and every price-dependent feature — craft
profit, the margin filters, tooltip price lines, the Bazaar's rates — silently reports nothing.

**Where the foreign format came from is not established.** The rich per-day high/low shape is
modern Auctionator's, not this 2.9.9 fork's, and the file supplied was named
`Auctionator_Price_Database.lua` rather than this addon's own
`Auctionator-Finder-Ascension.lua`. Three possibilities, and the fix differs for each:

1. **The dump is simply another addon's file** and this fork's own saved variables are fine. In
   that case nothing is wrong and this item closes. Most likely, and cheapest to check.
2. **Another Auctionator has been run alongside this one**, which the addon's own `README.md`
   warns against in its first lines — same globals, same saved variables. The 3 plain-number
   entries sitting among 178 tables on `Bronzebeard - Warcraft Reborn_Alliance` are what that
   would look like: this fork writing into a table another addon owns.
3. **Ascension ships its own Auctionator variant** that wrote the file.

**Closed by the owner, 2026-08-19, and it was none of the three.** `Bronzebeard - Warcraft
Reborn` is a **predecessor of the realm actually in use** — Rexxar - Conquest of Azeroth is the
new version of that server, similar enough that some naming carried over. All scanning has only
ever been done on Rexxar - CoA, whose two keys are the plain numbers this addon reads and
writes. The table-shaped entries are a historical residue under realm keys that never match at
runtime, so nothing reads them and nothing is broken. No code, no shim, no warning: **the fix
was a question.**

Worth keeping in mind if a realm is ever renamed *into* one of those keys, and worth keeping as
the reason this item existed — the shape is real, it is just not this realm's.

**If it turns out to be real**, the fix is small but the decision is not: read `mr` when an
entry is a table (a compatibility shim for a format we do not write), or detect the foreign
shape and warn the user that two Auctionators are fighting over one saved variable. The second
is more honest, since silently half-adopting another addon's schema invites the two to keep
overwriting each other.

**Note for item 8 (Advisor), if the format is ever adopted:** those `H<day>`/`L<day>` keys are
a real dated high/low series — `Mithril Ore` carries `H5457/L5457` and `H5456/L5456`. That is
exactly the price history `FRAMEWORK.md` §5 says does not exist here. It is not *our* data and
this fork does not produce it, so §5 stands as written for this addon — but it shows the shape
an Advisor would want, and is worth remembering when that item is scoped.

---

## 11. Transmutes get no craft cost or profit — DONE

**Found by the owner, 2026-08-19**, hovering `Transmute: Arcanite` in an Alchemy window: the
tooltip showed Vendor, Auction and Auction median for **Arcanite Bar** and then stopped. No
`Craft cost`, no `Craft profit`, not even the `Craft cost unknown` line that a craftable-but-
unpriceable item is supposed to get.

**Cause: this file assumed a row's name is its product's name**, which is true of nearly every
recipe and false of a transmute. `Transmute: Arcanite` makes `Arcanite Bar`. Two things broke
on that, in two different places:

1. **The sort.** `Atr_ProfSort_RowProfit` looked the market price up under the ROW name, so
   every transmute came back unpriced and sank below every priced recipe with a blank profit —
   the identical symptom, from the identical cause, as the enchanting rows in item 2. Item 2's
   write-up said a named helper would be wanted "for any craft whose row name is not its
   product name"; this is that craft, and it did not get one at the time.
2. **The craft-cost tooltip.** Both of its sources have to FIND the recipe that makes the
   hovered item, and both match on the produced item's ID or on the row's NAME. The name match
   cannot work for a transmute, so the whole thing rests on the ID — and this client hands back
   no item link for some rows, the quirk the `SetTradeSkillItem` hook already works around by
   reading the link back off the *rendered* tooltip. When that happens there is nothing left to
   match on, no row is found, and `isCraftable` stays false: hence silence rather than a wrong
   number.

**Built.**

- `Atr_ProfSort_RowSellName(i)` (`AuctionatorFinderProfession.lua`) — the item name a row's
  output is listed under. Enchant → the scroll; anything else → the produced item's name read
  off its own link, with the row name as the fallback for a row with no link. One helper now
  answers a question three call sites were each answering their own way.
- **The craft-cost tooltip no longer searches when it does not have to.** The trade skill hook
  knows exactly which row the tooltip is for, so `ShowTipWithPricing` and
  `Atr_AddCraftProfitToTip` take an optional `skillIndex` and cost straight off it. Exact,
  cheaper than the scan it replaces, and immune to both failure modes above — including the
  nil-link one, which no amount of better matching could have fixed. It also proves the recipe
  exists, so an unpriceable transmute now says `Craft cost unknown` instead of nothing.
  Reagent hovers still go the ordinary way; every other tooltip caller passes no index and is
  unaffected.
- `/atrprofsort <text>` prints each row's **produced item link**, or says the harvest skips the
  row when there is none. That is the datum that separates "no link" from "unpriced reagent",
  and it is what would have named this bug from the first report.

**Verified** under bare `lua5.1` against a mock trade skill window: the sell name for an
ordinary craft, a transmute, a transmute whose link is nil, and an enchant; the transmute
pricing and ranking rather than sinking; the unpriceable row still sinking; and the row-index
route costing a transmute that the name match cannot find at all. **Not verified in game.**

**Still open:** whether the profession **harvest** stores transmutes. It keys by produced-item
ID and skips any row without an item link, so on a client that returns none for these rows the
Sell tab's Crafted Goods Margin filter and a bag tooltip (profession window closed) will still
have no cost for `Arcanite Bar`. The trade skill window itself is now correct either way. The
new `made link:` line in `/atrprofsort transmute` answers it in one command.

---

## 12. NEW — same-name item variants share one price, and the Sell tab picks the wrong one

**Seen, 2026-08-19.** The owner holds the **epic** `Bloodforged Imperial Jewel` (ilvl 61,
requires 60, +9 Stamina). Ascension also has a **rare** one of the same name (ilvl 57, requires
55, +7 Stamina). Only the rare is listed on the auction house at the moment. Dropping the epic
into the Sell tab priced it off the rare's listings, and the two items' tooltips showed
identical `Auction` (9g75s) and `Auction median` (12g33s75c) lines. `Vendor` matched too;
`Disenchant` was the one line that differed (11s17c vs 18s94c).

That last detail is the diagnosis, not a footnote. `Atr_CalcDisenchantPrice` is computed live
from the item's own type, rarity and level (`AuctionatorHints.lua:2158`), so it splits the two.
Everything that differed *not at all* is read from a table keyed by **name**.

**This is not one bug, it is the addon's key.** Name is the primary key throughout:

- `gAtr_ScanDB[name]` — the scanned auction price. Written at `AuctionatorScan.lua:668` and
  `:1357`, read by the Sell recommendation, the Bazaar (`AuctionatorBazaar.lua:2938`), the
  Finder's price DB (`AuctionatorFinderPriceDB.lua:159`, `:320`, `:401`) and the bag tooltip
  (`AuctionatorHints.lua:287`).
- `AUCTIONATOR_PRICING_HISTORY[itemname]` — your own posting history (`Auctionator.lua:3394`
  onwards).
- `gItemLinkCache[string.lower(itemName)]` — **one link per name**. `Atr_GetItemLink`
  (`Auctionator.lua:443`) returns whichever variant was cached first, or whatever
  `GetItemInfo(name)` happens to resolve to. `AtrScan:Init` seeds `self.itemLink` from it
  (`AuctionatorScan.lua:152`), which is where "picks the first one seen" actually happens.
- `AtrScan.items[name]` — the scan's own bucket per item.

**There is already a variant split, and it is the wrong test.** `AuctionatorScan.lua:342`
compares each listing's **texture** to the bucket's, and on a mismatch appends a space to the
name to open a second bucket. Both Bloodforged Imperial Jewels use the same icon, so they land
in one bucket. `GetAuctionItemInfo` hands that same loop `quality` and `level`, and
`GetAuctionItemLink` hands it the item id — the loop uses neither for the split.

**And the raw data cannot be re-partitioned afterwards.** `AtrScan:AddScanItem`
(`AuctionatorScan.lua:381`) stores only stack size, buyout, owner and page. The row's link is
consulted once, under `if (scn.itemLink == nil …)` at `:356`, so a bucket that already has a
link from the name cache never learns what the listings actually are.

**The Sell side has a signal it throws away.** `GetAuctionSellItemInfo()` returns
`name, texture, count, quality, canUse, price`. `Atr_SellItemButton_OnEvent`
(`Auctionator.lua:1491`) reads all six and uses only `texture`. Quality alone would have split
this case (epic vs rare); the item's real link is available too, via the bag slot that
`Atr_LoadContainerItemToSellPane` already knows.

**Where the work divides.** These are separable and worth keeping separate:

1. **Split the scan buckets on something that works** — quality, or required/item level, or the
   listing's item id — instead of texture, and record the row's link in `AddScanItem` so a
   bucket knows what it holds. Contained inside `AuctionatorScan.lua`; fixes the *displayed*
   list on the Sell and Buy tabs.
2. **Give the Sell tab the item it was actually handed**, from `GetAuctionSellItemInfo`'s
   quality or from the bag link, rather than resolving the name through `gItemLinkCache`.
   Contained; fixes the recommendation for the item in the drop box.
3. **Re-key the price database off the item id.** This is the real one. It changes a saved
   variable that every consumer above reads, needs a migration for existing data, and needs an
   answer for names that legitimately have one price. Not a UI change — do 1 and 2 first and
   see how much of the symptom is left.

**Not yet known:** how common this is on Ascension. Two same-name variants of one gem is one
sighting; whether the server does this broadly (custom itemsets, difficulty tiers) decides
whether 3 is worth its cost or whether 1 and 2 are the whole fix. A `SavedVariables` dump would
answer it — duplicate names carrying wildly split prices are visible in the DB.

---

## Suggested order

Items 2, 3 and 11 are **done**, and item 10 closed on the owner's answer without any code
(2026-08-19). What is left, in order:

1. **Items 5, 1** — the last of the fully-decided, self-contained UI changes, and small enough
   to land together. Item 5 has one thing to get right (the persisted `reqOnly` has to be
   honoured from the user's own click once the auto-tick block stops writing it); item 1 has
   three (the hidden icon must survive `recommendElements` re-showing the block, the tooltip
   owner must move off the hidden frame, and the new hover target must be re-sized whenever the
   name changes).
2. **Item 4** — Finder stats dropdown. Decided in full ("learn, don't seed"), no open
   questions, and a real ordering fix for the user: pick the stat, *then* search.
3. **Item 6** — Finder recipe filter, once someone has confirmed in game whether Ascension's
   recipe tooltips carry the stock `ITEM_SPELL_KNOWN` string. Blocked on that, not on code.
4. **Item 7 (Ledger)** — the biggest new surface, and it unblocks 8 and 9.
5. **Item 8 (Advisor)** — scope after the Ledger, and only once the price-series question
   under "Still open" is answered.
6. **Item 9** — investigate with ledger data in hand.

**Item 12** does not have a place in that line yet. Its parts 1 and 2 are small and could go
any time; part 3 re-keys the price database and should not be started before someone has looked
at a `SavedVariables` dump to see how many names actually collide.

## What a SavedVariables dump answers

The owner offered their in-game Auctionator database, which is cheaper than a diagnostic for
most open questions and needs no code. The file is the **account-level** one —
`WTF/Account/<ACCT>/SavedVariables/Auctionator-Finder-Ascension.lua`, not the per-character
copy; `tools/README.md` explains why and how to take one cleanly (fully exit the client first,
or the last session's learning is missing).

What each open question gets out of it:

| Question | Variable | What settles it |
|---|---|---|
| Are scrolls named `"Scroll of <enchant>"`? | `AUCTIONATOR_PRICE_DATABASE` | The DB is name-keyed, so the scroll names are literally the keys. Definitive. |
| Which item is the vellum here? | `AUCTIONATOR_NPC_PRICES` | itemID → price, so an entry near the observed 2g40s is the candidate. **Needs an enchanting vendor to have been opened** — the supplied dump was the price DB only, so this is still open. |
| Was enchanting really absent from the harvest? | `AUCTIONATOR_CRAFT_RECIPES` | Confirms the item 2 diagnosis outright — pre-fix there should be no enchant entries at all. |
| What yield was harvested for a multi-output recipe? | `AUCTIONATOR_CRAFT_RECIPES[id].made` | **Partial.** This field stores `GetTradeSkillNumMade`'s FIRST return only. A `made = 1` on a recipe known to make 3 proves `minMade` is 1 — but not whether `maxMade` is 3 (a one-line fix) or also 1 (needs the manual box). Only `/atrprofsort distilled` separates those two. |
| Does a market price series exist? | `AUCTIONATOR_MEAN_PRICE_DATABASE` | Confirms `FRAMEWORK.md` §5 against real data — the sample arrays should carry no timestamps. |

**Taken 2026-08-19 (price DB only).** It confirmed the scroll naming and corrected the vellum
assumption — see item 2. It also surfaced a new issue, item 10 below, which the addon's own
code did not predict. Still wanted: `AUCTIONATOR_NPC_PRICES` and `AUCTIONATOR_CRAFT_RECIPES`
from the same account, which the supplied file did not include.

## Answered by the owner, 2026-08-19

- **Item 5:** "My iLvL" means the **My Lvl** checkbox (`Atr_Finder_ReqCheck`). Stop it
  auto-ticking; leave `Usable` and the min-level auto-fill as they are.
- **Item 7:** rename the **existing** tab to **History**; "Ledger" becomes the new
  transaction record.
- **Item 3:** **diagnostic first.** Read `GetTradeSkillNumMade`'s real returns off a live
  Alchemy window before any manual-yield UI is written.
- **Item 4:** **learn the stats, don't seed them.** No static stat list — the addon remembers
  what it has seen and offers that from then on.

## Still open

- **Item 3:** whether 30g51s99c per flask is *right* — i.e. whether the reagent prices behind
  it are. The maths and the display are settled; nothing shipped tests the inputs. The
  `Craft cost x3` line makes it a glance: 91g55s97c of reagents against a 127g80s stack of 3.
- **Item 2 (built, needs one in-game check):** whether the *weapon* vellum's name is in the
  candidate list, and whether both vellums price from a vendor rather than the auction house.
  `/atrprofsort stamina` answers both. Neither breaks the numbers if wrong — see item 2.
- **Item 6:** whether Ascension's recipe tooltips carry the stock `ITEM_SPELL_KNOWN`
  ("Already known") string.
- **Item 11:** whether the profession harvest stores transmutes at all — i.e. whether this
  client returns an item link for those rows. Decides only whether the Sell tab and bag
  tooltips know an `Arcanite Bar`'s craft cost with the profession window closed; the trade
  skill window is correct either way. `/atrprofsort transmute` now prints the link.
- **Item 8:** what `AUCTIONATOR_PRICE_DATABASE` actually retains — a current price, or a dated
  series. The advisor cannot exist without a series, and that answer decides whether item 8 is
  a feature or a data-plumbing project.
- **Item 9:** parked by the owner until item 7 lands.
- **Item 12:** how many item names on this server carry more than one variant. One sighting so
  far (`Bloodforged Imperial Jewel`, rare and epic). The answer decides whether the fix is two
  local changes or a re-keyed price database.
