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

**Confirmed harvesting, from the first real dump (2026-08-19).** `AUCTIONATOR_CRAFT_RECIPES`
holds 191 recipes, **88 of them `Scroll of Enchant ...`**. Pre-fix the diagnosis was that
enchanting was absent from the harvest entirely; it is plainly not absent now. The other 103
are crafted items (blacksmithing/tailoring names). **Every key is a string name — zero numeric
keys**, so `Atr_Craft_GetRecipe`'s itemID path is dead in practice and only the name fallback
ever fires. Worth knowing before item 12 touches name-keying.

**The vellum question is answered, 2026-08-19 — and answering it cost a bug fix.**
`AUCTIONATOR_NPC_PRICES` was empty, and stayed empty after the owner visited two supply vendors
and reloaded, because `Atr_NPC_HarvestMerchant` could never store anything (item 14). After that
fix, one vendor visit filled it — and **two items sit at exactly 2g40s: `52510` and `52511`**,
the armor and weapon vellums this server splits them into. The owner's observed price was right
to the copper.

**And the vellum was being costed from the auction house all along.** The price database carries
both names — `Enchanting Vellum - Armor` at **6g85s** and `Enchanting Vellum - Weapon` at
**3g22s** — which is what enchant craft costs were using, because `Atr_Craft_IDForName` sits in
the same file as the missing `zc` capture and returned nil, so `Atr_Craft_ReagentPrice` could
never reach its step-1 NPC branch. Every armor-vellum enchant was overstating its craft cost by
**4g45s** and every weapon one by **82s**. Both now price at the vendor's 2g40s, which is what
the cascade was written to do.

The `ATR_ENCHANT_VELLUM_COLD = 24000` fallback turns out to have been exactly right — it was
just never the value being used.

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

**Settled 2026-08-19, from a live alchemy window after item 14's fix.** The harvest now stores
**ten recipes at `made = 3`** — the Blightroot Extract flask family — and one at `made = 2`. The
yield is being read correctly off the window; no manual-yield box is needed for these.

**And the disputed number reproduces exactly.** Costing recipe `967456`'s reagents against this
same dump's price database gives **91g55s99c per craft, 30g51s99c per flask** — the figure in
this item, to the copper. So the arithmetic is not in question; the *inputs* are, and the
sensitivity is concentrated in one of them:

```
Fiery Frond x1         4g55s99c
Blightroot Extract x1 10g00s00c
Mountain Silversage x10 8g00s00c
Essence of Earth x2   69g00s00c   <- 75% of the craft cost
```

**Essence of Earth at 34g50s each is the whole question.** If that price is real, 30g51s99c is
real. Nothing in the addon can check it; a glance at the auction house can. Note every reagent
here priced from the AH — none is vendor-sold, so the NPC path does not soften it.

**Checked, 2026-08-19: the price is real.** The owner searched it — "yes its really high like 32g
ish" — and a fresh scan re-priced it at exactly **32g**. So the reagent is genuinely that
expensive, the craft cost is genuinely that high, and **item 3 is closed on all counts**: the
yield reads correctly, the arithmetic reproduces to the copper, and the inputs are real. The
per-flask figure moves with the market (32g rather than 34g50s puts it near 28g85s), which is the
point of computing it live.

What the earlier dump had already proved is that
`GetTradeSkillNumMade`'s first return is **not universally clamped to 1 on this server** —
three scroll recipes are stored `made = 2`. So a flask recorded as `made = 1` would be a real
reading of `minMade`, not an API that always says one.

---

## 4. Finder — stats dropdown usable before a search has run — DONE

**Asked:** on the Finder page have the stats dropdown available before seeing them in results.

**What it was.** `gFdr_StatKeys` was rebuilt from the *results* of the last scan, so before the
first search the dropdown read `(clear all)` and nothing else. That is the wrong way round: the
stats are a **filter** (`Fdr_PassesStatFilter` — a selected stat a row lacks removes the row),
so the natural flow is pick the stat, then search.

**Decided (owner, 2026-08-19): learn, don't seed.** No static `ITEM_MOD_*` list. The addon
remembers every stat key it has ever seen on gear and offers the accumulated set from then on:
empty on a fresh install, filling in as you search. That sidesteps both problems a static seed
had — stock keys that may not apply on this server, and Ascension's custom stats, which no
constant covers and which a seed would have had to fall back to discovery for anyway.

### What shipped

All of it in `AuctionatorFinder.lua`.

- **`Fdr_LearnedStats()` / `Fdr_LearnStatKeys(seen)`** (next to `Fdr_StatDisplayName`). The set
  lives at `AUCTIONATOR_FINDER_SETTINGS.statKeys` as `key -> true`. That variable is already an
  account-wide SavedVariable, so **no `.toc` change**; account-wide is right, because stats are
  a property of the server's items, not of a character.
- **Learning reads the RAW discoveries.** `Fdr_LearnStatKeys` is called from
  `Fdr_AnalyzeResults` on `statSeen`, *before* the `ubiquitousConstant` filter that produces
  `gFdr_StatKeys`. This is the part that was easy to get wrong: `ubiquitousConstant` is a
  judgement about one result set (a search narrow enough that every hit carries the same
  +10 Stamina drops Stamina), so persisting the filtered list would make what gets learned
  depend on the shape of past searches. It stays a display rule for the current results only.
  `FDR_DPS_KEY` is excluded from the learned set, for the same reason it is excluded from
  `gFdr_StatKeys` — DPS has its own column.
- **`FDR_STAT_LEARN_CAP = 400`, and it complains rather than truncating.** The set is bounded
  by the number of distinct stat keys that exist, so the cap is insurance against a malformed
  key written in a loop, not a real limit. On hitting it the addon says so in chat once per
  session and names the escape hatch: **`Atr_Finder_ForgetStats()`**, a global that empties the
  set (`/run Atr_Finder_ForgetStats()`). That function is the only way to clear junk.
- **`Fdr_StatDD_Initialize` lists two groups**: the stats in the current results first (still
  `gFdr_StatKeys`, so still `ubiquitousConstant`-filtered), then the rest of the learned set.
  Before a search there is only the second group, which is the point of the item.
- **The second group is dimmed** (`|cff808080`) when the entry is not in the current results,
  because selecting it there *will* empty the list — `Fdr_PassesStatFilter` removes any row
  missing a selected stat. Dimming makes that predictable rather than surprising.
- **Dimming tests against `gFdr_StatSeenKeys`, not `gFdr_StatKeys`.** A stat dropped by
  `ubiquitousConstant` is still present on every result, so selecting it empties nothing and it
  must not be dimmed as though it would. `gFdr_StatSeenKeys` is the raw per-scan key set, kept
  for exactly this. With no results at all nothing is dimmed — there is nothing to warn about.

Nothing else needed plumbing: `Fdr_StatDisplayName` already de-tokenises unknown keys, so a
learned custom stat gets a readable label; the dropdown rebuilds through
`UIDropDownMenu_Initialize` on every open, so a grown set appears with no refresh; and a
selection already survives its stat vanishing from results, so pre-selecting before a scan
persists with no extra work.

**Verified** by `luac5.1 -p` and by reading the call order (both new entry points run long after
SavedVariables load — `Fdr_AnalyzeResults` post-scan, the dropdown on user click).

**Verified in game, 2026-08-19.** Two Finder searches on the merged build (`Essence of Earth`,
`Bloodforged`) left **31 keys in `AUCTIONATOR_FINDER_SETTINGS.statKeys`** — the 24 stock
`ITEM_MOD_*` stats, six `RESISTANCE*_NAME` keys, and **`PVP_POWER`**. That last one is the whole
argument for "learn, don't seed" arriving as evidence: it is an Ascension custom stat, no stock
constant covers it, and a static seed would have missed it.

One cosmetic follow-up, not worth a change on its own: `Fdr_StatDisplayName` has no `_G` entry for
`PVP_POWER`, so its de-tokenising fallback renders it **"Pvp power"**. Correct and readable, just
not how anyone writes it. If a future edit touches that function, upper-casing each word would
give "Pvp Power"; getting "PvP Power" needs a special case, which is not worth carrying. The thing to look at first is **menu height**: the list can now hold every
stat the account has ever seen (realistically 30–50 entries) where it used to hold one scan's
worth, and 3.3.5's `UIDropDownMenu` has no scrollbar — it can only flip above the button. If it
runs off screen, that is the follow-up, and paging is the fix, not a smaller learned set.

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

## 6. Finder — filter recipes by already-learned — DONE

**Asked:** if searching recipes on the Finder, have a filter for already learned.

**Shipped 2026-08-19.** A checkbox in the Finder options panel removes recipe listings this
character has already learned.

### How "known" is decided

There is no API on 3.3.5 that answers "have I learned recipe item X". The only signal is the
`ITEM_SPELL_KNOWN` line the client itself adds to a recipe's tooltip, so
`Atr_Craft_IsRecipeKnown` (`AuctionatorFinderProfession.lua`) reads it off a hidden tooltip —
the same technique the Finder already uses for a listing's true item level.

**Deliberately a TEXT test, not the colour test `USABLE-SCAN.md` documents.** That doc was the
obvious model and it is the wrong one here: on a recipe tooltip the same unmet-requirement red
also paints `Requires Enchanting (300)` and a too-high required level, so a recipe you *cannot
learn* would read as one you *already know* — the exact inversion, and it would hide the row.
What did carry over is the blank-line lesson: only a line with text is tested, because
`GameTooltip` reuses its FontStrings and `ClearLines` only hides them.

The wording comes from `_G.ITEM_SPELL_KNOWN` rather than a literal, so a re-worded or localised
client still matches; a lower-cased `"already known"` substring is the fallback.

### The cache, and why it can be persisted safely

`AUCTIONATOR_KNOWN_RECIPES`, **per character** — the one `SavedVariablesPerCharacter` addition
this addon has needed in a while, because an alt has not learned your main's recipes. That is a
`.toc` change, unlike item 4's.

**Only "known" is ever written, never "not known."** Learning a recipe moves unknown → known and
nothing in the game moves it back, so a stored `true` cannot go stale; a missing entry just means
"scan again". That is the whole reason a persisted cache is safe here.

**When in doubt, do not hide.** An item the client has never cached renders a stub tooltip with
no known-line, which reads as "not known" and leaves the row on screen. Showing a recipe you own
is a mild annoyance; hiding one you wanted is a lost purchase.

### Where it hooks in

- **`Fdr_PassesKnownFilter`** joins `Fdr_PassesFilters`, the single choke point both the grouped
  and ungrouped display paths already run every row through.
- **Gated on the item class for cost, not correctness.** The class name comes from
  `GetAuctionItemClasses` (which returns the same strings `GetItemInfo` does — see
  `Fdr_IsGearClassName`), so it reads right on a localised client; `"Recipe"` is kept as a
  fallback. If neither matches the filter simply stops hiding anything.
- **The verdict is memoised on the record**, because a rebuild runs on every sort and column
  change and a tooltip scan per row per rebuild would be felt.
- **`Atr_Craft_HarvestRecipeTooltip` warms the cache for free** — it is already walking a
  rendered recipe tooltip for reagents, so it reads the known-line in the same pass, which is
  what this item's original plan asked for.

### Where the checkbox went, and why not where the plan said

The plan said "next to `Usable`/`My Lvl`". **The Finder's control row has no space left**: the
search box, Categories, the level range, three checkboxes and the stat dropdown run from x=72 to
x=732 with no 24px gap anywhere. Adding a second control row would push the results grid down and
cost one of the 15 visible rows. Asked the owner (2026-08-19), who chose the **Finder options
panel** — no layout risk, alongside the existing scan options. `Fdr_Options_Apply` triggers a
rebuild so a toggle takes effect on results already on screen.

The preference is account-wide (a habit) even though the knowledge is per character.

**Verified** by `luac5.1 -p` on all three changed files. **Not verified in game.** Two things to
look at first: whether Ascension's recipe tooltips carry the stock string at all (the original
open question — if they do not, nothing is hidden and nothing breaks), and whether the class name
at index 9 of `GetAuctionItemClasses` really is Recipe on this server.

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

**Closed by the owner, 2026-08-19.** `Bronzebeard - Warcraft Reborn` is a **predecessor of the
realm actually in use** — Rexxar - Conquest of Azeroth is the new version of that server,
similar enough that some naming carried over. All scanning has only ever been done on
Rexxar - CoA, whose two keys are the plain numbers this addon reads and writes. The
table-shaped entries are a historical residue under realm keys that never match at runtime, so
nothing reads them and nothing is broken. No code, no shim, no warning: **the fix was a
question.**

**Confirmed later the same day, and it was possibility 1 — the dump was simply another addon's
file.** The owner listed `Interface/AddOns` and the account's `SavedVariables`:

- **Only `Auctionator-Finder-Ascension` is installed.** There is no `Auctionator`,
  `Auctionator_Price_Database` or `Auctionator_Pricing_History` folder, so possibility 2 (two
  Auctionators sharing globals) is ruled out, not merely unlikely. Stock Auctionator splits its
  two big tables into companion addon folders and therefore writes three files; this fork
  declares everything in one `.toc` and writes exactly one. Three files means three folders once
  existed.
- **Those three files are frozen at `Jul 21 16:31`** — all to the same minute, one final logout —
  against `Aug 19 08:31` for this addon's own file. The analysed `Auctionator_Price_Database.lua`
  was 82 KB; `Auctionator-Finder-Ascension.lua` was 1.14 MB.

So the foreign shape was read out of a file that **no installed addon can load**. SavedVariables
are loaded per addon folder, and those folders are gone: this fork has never had those rows in
memory and could not. That closes the item on evidence rather than on inference — the realm-key
explanation above still holds, and is now the second reason rather than the only one.

**And the real file, read 2026-08-19, is uniform.** `AUCTIONATOR_PRICE_DATABASE` holds exactly
one realm key — `Rexxar - Conquest of Azeroth_Alliance`, 5267 entries, **every value a plain
number, zero tables** — beside one top-level scalar, `__dbversion = 2`. No Bronzebeard key
exists in this addon's data at all. There is nothing here this addon cannot read.

Worth keeping in mind if a realm is ever renamed *into* one of those keys, and worth keeping as
the reason this item existed — the shape is real, it is just not this realm's, and it is not
even this addon's file.

**What it cost:** every conclusion drawn from that dump was drawn from a month-stale file
belonging to a different addon. The item 2 findings that survive it (scroll naming, the vellum
correction) survive because they are about what items on the server are *called*, which does not
depend on who wrote the file. Nothing that dump said about *this* addon's database was ever
evidence. Hence the file-name warning now sitting at the top of the next section.

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

**That split already writes to the price database, and it is ugly.** The space-suffixed name
becomes the bucket's `itemName` (`AtrScan:Init`, `AuctionatorScan.lua:135`), and the finaliser
writes `gAtr_ScanDB[scn.itemName]` (`:668`) — so **the live database already contains
`"Some Item "` keys** wherever the texture test has fired. Two consequences:

- **A dump measures the problem for free.** Grep the saved variables for keys with a trailing
  space: that is the count of variant pairs the *texture* test caught. It is a floor, not the
  answer — the Bloodforged case is precisely one the texture test misses — but it costs nothing
  and it is real data about how common variants are on this server.
- **Part 1 has a decision to make before any code**: whether the new split *replaces* the
  trailing-space hack or sits alongside it, and what happens to the space-keyed rows already in
  people's databases. Replacing it is the honest answer, but it orphans those rows and they
  will keep answering lookups for a name nobody queries. That decision is not made yet, and it
  is the only thing standing between part 1 and someone writing it.

  **Measured, 2026-08-19, and it is cheap: three rows.** Of 5267 price-database entries exactly
  **3** carry a trailing space, and the same 3 appear in the mean database:

  ```
  ["Plans: Splintering Staff "]            = 44g60s
  ["Plans: Effigy of Overgrowth "]         = 18g45s
  ["Duskrune Chopper Cache (Backsheath) "] = 300g
  ```

  **None of the three has an unsuffixed twin** — `db["Plans: Splintering Staff"]` is nil. So
  they are not "second variants beside a first", they are the only row those items have, and
  replacing the hack orphans nothing that a competing row would shadow. The migration is
  therefore: strip the trailing space, adopt the value, done — three rows, no merge conflict,
  no `__dbversion` bump. **Part 1 is startable.**

  Two things the sample says about the *texture* test itself: it fires roughly once in 1800
  entries, and all three hits are recipes or a container — **not gear**. The Bloodforged case,
  which is gear, is exactly the one it misses.

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
   list on the Sell and Buy tabs. **One decision left — see "What part 1 ran into" below.**
2. ~~**Give the Sell tab the item it was actually handed**~~ — **DONE 2026-08-19, and the
   mechanism was not the one written here.** See "Part 2 as built" below.
3. **Teach the price database about variants.** The real one. See the recommended shape below
   — the summary is that it should *not* be a re-key.

### Part 2 as built (2026-08-19)

**The premise above was wrong, and worth correcting because it would have sent someone to the
wrong file.** The Sell tab does *not* resolve its item by name through `gItemLinkCache`.
`Atr_GetSellItemInfo` (`Auctionator.lua:907`) reads the link off
`AtrScanningTooltip:SetAuctionSellItem()` — the one source a name cannot confuse — and writes it
into the cache. By the time `DoSearch` runs, the cache already holds the right link.

**The real cause is scan REUSE.** `Atr_FindScan` (`AuctionatorScan.lua:97`) caches scan objects by
lowercased name and **only re-`Init`s when explicitly asked**:

```lua
if (gAllScans[itemNameLC] == nil) then ... scn:Init (itemName) ...
elseif (init) then gAllScans[itemNameLC]:Init (itemName); end
```

`AtrSearch:Init` reuses a scan whose `whenScanned` is inside the rescan threshold without
re-initialising it, so the scan keeps the `itemLink` — and with it the `itemQuality`, `itemClass`
and `itemSubclass` that `UpdateItemLink` derives — of **whichever variant was seen first**. Drop
the epic in the sell box after the rare has been scanned and the pane describes the rare. That is
the reported symptom, and it is a different bug in a different file from the one this item
predicted.

**The fix** is three lines in `Atr_OnNewAuctionUpdate`: after `DoSearch`, if the sell item's real
link disagrees with `gSellPane.activeScan.itemLink`, push it in through the existing
`AtrScan:UpdateItemLink`, which recomputes quality, class and subclass from it. The scanned
*listings* are deliberately left alone — they are name-keyed and still the right search. This
corrects the item's **identity**, not its market data; the market data is part 3.

**Verified** by `luac5.1 -p`. **Not verified in game.** The check is the reported case: scan the
rare Bloodforged Imperial Jewel, then drop the epic in the sell box and confirm the header name
colours epic and the disenchant line matches the epic.

### What part 1 ran into (2026-08-19) — one decision, and it is the owner's

Started part 1 and stopped before writing the split, because the measurement that unblocked it
uncovered a second decision underneath. Recording it rather than guessing, since the wrong pick
changes **what gets written to the price database**.

**The bucket key and the database key are the same field.** The scan loop keys `self.items` by
name, the space hack makes a second bucket by making a second *name*, and the finaliser writes
`gAtr_ScanDB[scn.itemName]` (`AuctionatorScan.lua:668`). So *any* split into N buckets writes N
database rows unless the two identities are separated first. That is the whole reason the
trailing-space keys exist in people's databases at all — they are not a side effect, they are
what the design does.

Splitting on **quality** is the right test (free from `GetAuctionItemInfo`, and it separates the
reported rare/epic pair; splitting on *level* would explode on this server, where gear is scaled
per instance and every required level would become its own bucket). The open question is what the
new buckets do about the database:

| Option | Cost |
|---|---|
| **A. Variant buckets skip the DB write** — only the primary writes | Honest (there is nowhere correct to put a variant price until part 3), but the recorded price can **rise**: today the merged bucket writes the minimum across all variants, and the cheaper listing may be in the variant bucket. A price going up silently is the worst failure mode of the three. |
| **B. Give `AtrScan` a `baseName` separate from `itemName`** — buckets split, both write `gAtr_ScanDB[baseName]`, last one wins | Keeps the DB key clean and stops new trailing-space rows forever. "Last wins" is arbitrary, but no worse than today's single merged number, and it is the shape part 3 wants to build on. |
| **C. Merge the low prices across same-`baseName` buckets at finalise** | Preserves today's DB behaviour *exactly* while fixing the display. Most code, and it is throwaway once part 3 lands. |

**Recommendation: B.** It is the only one that leaves the database in the shape part 3 is
designed to extend, and its arbitrariness is bounded — one of two real prices for a name, where
today you also get one number for a name. A is a silent price increase, which this addon should
never do. C is work that part 3 deletes.

**The three existing trailing-space rows** need no migration under any option: none has an
unsuffixed twin, so they answer no lookup and shadow nothing. Stripping the space and adopting
the value would give three items a price they currently lack — a small win, worth doing in the
same pass, not worth a `__dbversion` bump.

**Deferred to part 3, deliberately:** recording each row's link in `AddScanItem`. It costs a
`GetAuctionItemLink` per listing across a full scan, and nothing reads it until the database can
store a variant. Doing it now would buy nothing and slow every scan.

### Recommended shape for part 3 (2026-08-19)

The owner's instinct — put the item's identifying data in the price database — is right. The
obvious way to do it is wrong, or at least much more expensive than it looks.

**Do not re-key the database from name to item id.** Keep the name as the key and let the
*value* carry variants:

```
gAtr_ScanDB[name] = 123456                          -- legacy: one price, no variants known
gAtr_ScanDB[name] = { ["1234:0"] = 97500,           -- itemId:suffixId
                      ["5678:0"] = 1233375,
                      dflt      = 97500 }           -- what a name-only lookup answers
```

Three reasons, in order of how much they matter:

- **A dozen callers have a name and nothing else, and always will.** `Atr_GetDEitemName(itemID)`
  turns an id into a name and then looks the name up (`AuctionatorHints.lua:617`); the
  profession code prices reagents and scrolls by name (`AuctionatorFinderProfession.lua:64`,
  `:220`, `:640`, `:1136`); the Bazaar prices `rec.name` (`AuctionatorBazaar.lua:2938`);
  `Atr_GetAuctionBuyout` is a public API taking either (`AuctionatorAPI.lua:47`). Under
  id-keying every one of those becomes unanswerable, and the fix is to build a name→ids index
  and a policy for picking among them — which is the variant-in-value design, arrived at by the
  expensive route and bolted on the side. Build it deliberately instead.
- **Migration becomes free.** A legacy `number` value simply *is* "one variant, unknown id".
  A `type(v) == "number"` branch handles every pre-existing row forever, so there is no
  `__dbversion` 3 rewrite and no risk of eating someone's database. The codebase already does
  exactly this shape for `gAtr_MeanDB` (`if (type (m) ~= "table") then m = {} end`,
  `AuctionatorScan.lua:1360`).
- **It stages.** Only callers that actually know the variant need to change, one at a time —
  the Sell tab, the AH/bag tooltip (which already computes `itemID`, `AuctionatorHints.lua:2160`),
  the sell-browser rows (`Auctionator.lua:1792`, `:2184`). Everything else keeps working
  unchanged on the default.

**The seam is already there.** `Atr_GetAuctionPrice` and `Atr_GetMeanPrice`
(`AuctionatorHints.lua:273`, `:318`) are the only two accessors, and **both already take
"itemName or itemID"** — and then convert the id to a name and throw it away. Giving them an
optional variant key, and making the id path keep the id instead of discarding it, is where
this change lives. `gAtr_MeanDB` needs the same treatment or the two tooltip lines will
disagree between variants.

**Use `itemId:suffixId` as the variant key, not the bare item id.** The format is already in
this addon: `AUCTIONATOR_PRICING_HISTORY[name]["is"]` stores `itemId:suffixId:uniqueId`
(`Auctionator.lua:4548`). Drop `uniqueId` — it is per-instance and would shatter the table.
Keeping `suffixId` matters because random-suffix gear is the *other* variant axis and the two
should not be conflated.

  Note while reusing that format: the existing parser has a copy-paste bug at
  `Auctionator.lua:4558` — `uniqueId = tonumber(suffixId)` reads the wrong variable. Harmless
  today because the value is only used to rebuild an item string where `uniqueId` rarely
  matters, but do not propagate it.

**What will actually break downstream, and it is not the readers.** Changing the value type
breaks the code that *walks* the table:

- `Atr_GetAHVariantEstimate` (`AuctionatorHints.lua:250`) iterates `pairs(gAtr_ScanDB)` and
  filters on `type(price) == "number"`. Variant rows become tables and would be **silently
  dropped from the estimate** — random-suffix gear quietly gets worse. This is the one to fix
  in the same commit, not after.
- `/atrprices list` does the same filter (`AuctionatorFinderPriceDB.lua:384`), and
  `Fdr_PriceDB_ResolveName` (`:265`) tests `gAtr_ScanDB[name] ~= nil` to decide a name is known.
- `Atr_GetDBsize` (`AuctionatorScan.lua:1066`) is a bare count and is fine.

**Note the two variant systems are unrelated and must stay that way.**
`Atr_GetAHVariantEstimate` handles random-suffix gear, where the variants have *different
names* ("Dreamdust Slippers of the Owl"). This item is the opposite case: *same* name,
different item. Neither mechanism can serve the other, and a fix that tries to unify them will
get both wrong.

**Do part 1 first regardless.** The database has nothing to store until the scan can tell the
variants apart: `AtrScan.items[name]` is one bucket per name and `AddScanItem` never records
the row's link. Part 3 without part 1 is a schema with no data.

**Measured 2026-08-19, and it cuts two ways.** A broad `Bloodforged` search (hundreds of gear
listings, price DB 5267 → 5471) was scanned and the dump re-read:

- **The texture test fired zero times on gear.** Trailing-space keys stayed at exactly 3, the
  same three recipes and container as before. Whatever the existing split is catching, it is not
  catching same-name gear — which is the case that was actually reported. Part 1's replacement is
  not competing with a mechanism that works; it is replacing one that is inert where it matters.
- **The reported item is in the DB and looks the part.** `Bloodforged Imperial Jewel` holds one
  price, 9g75s — exactly what the owner saw their epic priced at — over mean samples of
  `9g75s, 9g77s, 9g77s, 14g90s`. The 14g90s outlier is what a second variant looks like from
  inside a name-keyed table: not obviously wrong, just quietly averaging two different items.
- **148 of 5471 names (2.7%) carry mean samples splitting 5x or wider**, topping out at 130x
  (`Recipe: Distilled Flask of Adept Striking`, 7g64s → 998g99s) with 25–70x common among
  Bloodforged gear.

**Read that 2.7% carefully — it is a ceiling on the evidence, not a count of variants.** Three
different things produce a wide split under one name and this data cannot separate them: a true
same-name variant pair (item 12's case), Ascension's per-INSTANCE scaling of gear (the Finder's
own `rec.scaled` machinery exists for exactly this, and the Bloodforged names dominating the list
are all scaled gear), and plain outlier listings (a recipe is not scaled, so the 130x row is
market noise the mean DB deliberately keeps).

What it does establish is the thing part 3 needs: **one number per name is being asked to stand
for items that differ by 25x and more, on 2.7% of the database.** Whichever of the three causes
dominates, the value shape is wrong for those rows, and the variant-in-value design fixes it for
the first two without needing to tell them apart up front.

---

## 13. NEW — a third of the saved-variables file is redundant

**Measured 2026-08-19** from the first real dump: `Auctionator-Finder-Ascension.lua`,
**1,144,785 bytes**. Not a bug and not urgent — the client loads it fine — but the vendor-price
research (which was the right call, and is not what should be cut) has left two chunks that are
pure duplication, and both are cheap to stop writing.

| Variable | Bytes | Share |
|---|---:|---:|
| `AUCTIONATOR_MEAN_PRICE_DATABASE` | 394,144 | 34.4% |
| `AUCTIONATOR_VENDOR_LEARNED` | 360,970 | 31.5% |
| `AUCTIONATOR_PRICE_DATABASE` | 226,517 | 19.8% |
| `AUCTIONATOR_BAZAAR` | 67,886 | 5.9% |
| `AUCTIONATOR_CRAFT_RECIPES` | 60,860 | 5.3% |
| `AUCTIONATOR_ITEM_LOCATIONS` | 25,942 | 2.3% |
| everything else (12 variables) | 8,466 | 0.7% |

Inside `AUCTIONATOR_VENDOR_LEARNED`: `cb` 156,502 (13.7% of the file), `obs` 112,879 (9.9%),
`base` 54,663 (4.8%), `log` 34,589 (3.0%), `trk` 2,275.

### Trim 1 — the seed echo, ~152 KB (13%)

`obs` holds 1437 entries of which **1338 carry `seed = 1`**, and `base` 518 of which **449**
do. `tools/diff-vendor-seed.lua` against the shipped seed reports **1349 obs agree, 0 disagree,
0 contested, 0 malformed**, and **453 base agree, 0 disagree**. So ~93% of `obs` and ~87% of
`base` is a byte-for-byte copy of `AuctionatorVendorSeed.lua`, which already ships inside the
addon. Every user carries a private duplicate of a file they already have.

The real payload is small and is the part to protect: **88 new observations and 65 new base
facts** this dump contributed that the seed did not have.

**The mechanism already exists.** `AUCTIONATOR_VENDOR_LEARNED.seedver` records which seed built
the table (`"2026-08-16"`, matching the shipped one). The rule would be: drop seed-flagged
entries from the table at `PLAYER_LOGOUT` and re-merge from the seed at load — WoW serialises
whatever is in the table at logout, so *not persisting* something means removing it before then,
not skipping a write. When `seedver` does not match the shipped seed, keep everything as-is
rather than trusting a flag written against a different seed.

### Trim 2 — single-sample "means", ~232 KB (20%)

`AUCTIONATOR_MEAN_PRICE_DATABASE` holds 5267 entries and 8898 samples. **3810 of those entries
hold exactly one sample**, costing 231,629 bytes, and **1769 of them are byte-identical to the
`AUCTIONATOR_PRICE_DATABASE` row for the same name**. A one-sample mean is not a mean; it is the
same number written twice, in a table wrapper that costs ~60 bytes to say it.

Options, cheapest first: don't create the mean row until a second sample arrives; or store a
lone sample as a bare number and only promote to a table on the second (the codebase already
branches on `type(m) ~= "table"` at `AuctionatorScan.lua:1360`, so the reader is half-written).
Either way `Atr_GetMeanPrice` needs the scalar branch, and item 12 part 3's variant-in-value
design has to be written to expect it.

### What NOT to trim

- **`cb` (156 KB, 13.7%)** looks like the obvious target and is not. All 1299 entries hold a
  **single** sighting — the cap of 12 never binds — and only **97** of them also have a `base`
  fact, so 1202 are the only variant record their item has. It exists precisely because owning
  an item rewrites the client's on-disk cache and destroys the pre-purchase sighting
  (`AuctionatorHints.lua:909`). Deleting it to save bytes would silently degrade prediction.
- **`log` (34.6 KB, 3.0%)** — 109 rows, and `VENDOR-PRICE-RESEARCH.md` wants *more* of them, not
  fewer. It is capped at 500 already.
- **The price database itself (19.8%)** — 5267 plain numbers is what the addon is for.

### Not part of this item

`AUCTIONATOR_ITEM_LOCATIONS`, `AUCTIONATOR_BAZAAR` and `AUCTIONATOR_CRAFT_RECIPES` are all
proportionate to what they hold. `AUCTIONATOR_SELL_IGNORE` and `AUCTIONATOR_NPC_PRICES` are
empty — the second one is item 2's open check, not a size problem.

**Worth doing when?** Neither trim changes behaviour, so this ranks below anything the user can
see. It becomes worth doing if the file gets big enough to slow logout, or as tidy-up alongside
item 12 part 3, which has to touch both databases' value shapes anyway.

---

## 14. Two files never captured `zc`, so every itemID lookup in them was nil — DONE

**Found 2026-08-19** by the dump, not by a report. Two observations that looked unrelated —
`AUCTIONATOR_NPC_PRICES` empty after weeks of play, and `AUCTIONATOR_CRAFT_RECIPES` holding 191
recipes with **zero numeric keys** — are one bug.

`zc` is file-local in `zcUtils.lua` and exported only as `addonTable.zc`. Sixteen files capture
it with `local addonName, addonTable = ...; local zc = addonTable and addonTable.zc or _G.zc;`.
**Two did not**, so in those two `zc` resolved to a nil *global* — and because every use site is
written defensively as `zc and zc.ItemIDfromLink`, nothing errored. It just quietly did nothing,
forever.

**`AuctionatorFinderMerchant.lua` (1 use).** `Atr_NPC_HarvestMerchant` sets
`local ItemID = (zc and zc.ItemIDfromLink) or nil` and then stores under
`if (itemID) then db[itemID] = unit`. With `ItemID` nil the condition never held: **the NPC price
learner has never recorded a single item.** Confirmed twice over — the owner visited an
enchanting and an alchemy supply vendor, reloaded, and the table was still empty.

**`AuctionatorFinderProfession.lua` (11 uses).** Worse, because it silently halved a feature.
`Atr_Craft_Harvest` keys a recipe by its produced item's ID, *except* enchants, which are keyed
by scroll name:

```lua
if (Atr_Craft_IsEnchantLink(madeLink)) then madeID = Atr_Craft_ScrollName(rowName);
else                                        madeID = ItemID and tonumber((ItemID(madeLink))) or nil; end
if (madeID) then ... db[madeID] = ... end
```

With `ItemID` nil, `madeID` was nil for everything that is not an enchant, so **the
profession-window harvest stored enchants and nothing else.** The 103 non-enchant recipes in the
dump all came from the other source, the recipe-*tooltip* harvest, which is name-keyed and was
never affected. That is why the file has zero numeric keys, and why opening an alchemy window
produced no flasks, no transmutes and no `Arcanite Bar`: alchemy makes items, so every row hit
the dead branch. Reagent IDs were nil for the same reason; reagents still priced because the
record keeps the name too.

**The fix** is the capture those two files were missing, matching the other sixteen. Two lines
each, no logic touched.

**What it unblocks.** Item 11's open question is answered without an experiment — transmutes
were never stored, and the cause was not the item-link theory. Item 3 gets its flask yields the
first time an alchemy window is opened after the fix, and item 2 gets its vellum the first time
a supply vendor is. All three were waiting on data this bug was eating.

**Watch for on the next dump:** `AUCTIONATOR_CRAFT_RECIPES` will start carrying **numeric** keys
from the window harvest while the 103 existing name keys stay. That is expected and both readers
handle it (`Atr_Craft_GetCraftCost` tries ID then name), but a recipe seen from both sources will
occupy two rows. Harmless — the ID row wins and carries the better data — and worth folding into
item 13's tidy-up rather than fixing separately.

**Verified** by `luac5.1 -p`, by a repo-wide re-check that no other file has the same gap (the
only other hit, `AuctionatorQuery.lua`, uses `zc.` in commented-out debug lines only), and by the
two dumps that are the evidence for the diagnosis.

**Verified in game the same day**, on a third dump taken after installing the fix and opening one
supply vendor and one alchemy window:

| | before | after |
|---|---:|---:|
| `AUCTIONATOR_NPC_PRICES` | 0 | **9** |
| `AUCTIONATOR_CRAFT_RECIPES` | 191 | **286** |
| — of those, numeric keys | 0 | **95** |
| reagents carrying an item ID | 0 | **267** |

The 95 new rows are the window harvest working for the first time: ten `made = 3` flask recipes,
`Arcanite Bar` (`12360`), and 84 others. Both vellums appeared in `NPC_PRICES` at 2g40s. Items 2,
3 and 11 all closed on that one dump.

---

## Suggested order

Items 1–6, 11 and 14 are **done**, and item 10 closed without any code (2026-08-19). Rewritten
after the first real dump, same day. What is left, in order:

1. **Item 12 parts 1 and 2** — **now startable.** The dump measured the one decision part 1 was
   waiting on: three trailing-space rows, none with an unsuffixed twin, so replacing the texture
   hack orphans nothing. Part 2 (give the Sell tab the item it was handed) is independent and
   smaller still.
2. **Item 7 (Ledger)** — the biggest new surface, and it unblocks 8 and 9. One scope question
   to answer before the first row is written: auction house only, or vendor and mail too.
3. **Item 12 part 3** — the price database's value shape. Do it after part 1, which is what
   gives it data to store, and fold item 13's mean-database change into the same pass since both
   touch the same value types.
4. **Item 8 (Advisor)** — now known to be a data-plumbing project first: there is no price
   series, confirmed on real data. Scope after the Ledger.
5. **Item 9** — investigate with ledger data in hand.
6. **Item 13** — saved-variable trimming. Invisible to the user, so it ranks last on its own;
   worth folding into item 12 part 3 if that lands first.

## What a SavedVariables dump answers

The owner offered their in-game Auctionator database, which is cheaper than a diagnostic for
most open questions and needs no code. The file is the **account-level** one —
`WTF/Account/<ACCT>/SavedVariables/Auctionator-Finder-Ascension.lua`, not the per-character
copy; `tools/README.md` explains why and how to take one cleanly (fully exit the client first,
or the last session's learning is missing).

> **Take the file named after the addon folder, and no other.** This fork declares all 35 of its
> saved variables in one `.toc`, so **everything it owns is in `Auctionator-Finder-Ascension.lua`**
> — there is no companion file. A `SavedVariables` folder that has been through a few installs
> can also hold `Auctionator.lua`, `Auctionator_Price_Database.lua` and
> `Auctionator_Pricing_History.lua`; those are **stock Auctionator's**, which splits its big
> tables into companion addon folders. The 2026-08-19 dump was one of those by mistake, which is
> the whole of item 10 above. Size is the quick tell — this addon's file was 1.14 MB against
> stock's stale 82 KB.

What each open question gets out of it:

| Question | Variable | What settles it |
|---|---|---|
| Are scrolls named `"Scroll of <enchant>"`? | `AUCTIONATOR_PRICE_DATABASE` | The DB is name-keyed, so the scroll names are literally the keys. Definitive. |
| Which item is the vellum here? | `AUCTIONATOR_NPC_PRICES` | itemID → price, so an entry near the observed 2g40s is the candidate. **Needs an enchanting vendor to have been opened** — the supplied dump was the price DB only, so this is still open. |
| Was enchanting really absent from the harvest? | `AUCTIONATOR_CRAFT_RECIPES` | Confirms the item 2 diagnosis outright — pre-fix there should be no enchant entries at all. |
| What yield was harvested for a multi-output recipe? | `AUCTIONATOR_CRAFT_RECIPES[id].made` | **Partial.** This field stores `GetTradeSkillNumMade`'s FIRST return only. A `made = 1` on a recipe known to make 3 proves `minMade` is 1 — but not whether `maxMade` is 3 (a one-line fix) or also 1 (needs the manual box). Only `/atrprofsort distilled` separates those two. |
| Does a market price series exist? | `AUCTIONATOR_MEAN_PRICE_DATABASE` | Confirms `FRAMEWORK.md` §5 against real data — the sample arrays should carry no timestamps. |

**First dump, 2026-08-19 — and it was the wrong file.** It was stock Auctionator's
`Auctionator_Price_Database.lua`, a month stale and belonging to an addon no longer installed
(item 10). Its scroll-naming and vellum findings hold, because they are about item *names* on
the server. Nothing else it suggested about this addon's data was ever evidence.

**Second dump, 2026-08-19 — the real file**, `Auctionator-Finder-Ascension.lua`,
1,144,785 bytes. What it settled, row by row:

| Question | Answer |
|---|---|
| Are scrolls named `"Scroll of <enchant>"`? | **Yes** — 88 `Scroll of Enchant ...` keys in `AUCTIONATOR_CRAFT_RECIPES`. |
| Which item is the vellum here? | **`52510` and `52511`**, both 2g40s from a vendor — after item 14's fix made the harvest able to write at all. |
| Was enchanting really absent from the harvest? | **Confirmed fixed** — 88 of 191 recipes are enchants. |
| What yield was harvested for a multi-output recipe? | **`made = 3`, correctly** — ten flask recipes, once item 14's fix let the window harvest store items at all. |
| Does a market price series exist? | **No, confirmed on real data.** 5267 mean entries, 8898 samples, all bare numbers in an array, no timestamps, max 14 samples against the cap of 15. `FRAMEWORK.md` §5 stands. |
| How many same-name variants? (item 12) | **3 trailing-space keys in 5267**, none with an unsuffixed twin. Part 1 unblocked. |
| Is item 4's learning accumulating? | **Still unverified** — `statKeys` is absent from all three dumps. The third was taken on the merged build but without a Finder search having run, which is what writes it. |
| What is the price DB's shape? (item 10) | One realm key, 5267 entries, **all plain numbers**, `__dbversion = 2`. |

It also produced item 13 (a third of the file is redundant), item 14 (two files never captured
`zc`, so the NPC harvest never wrote and the profession harvest stored only enchants — found
because a *second* dump, taken straight after two vendor visits, was byte-identical apart from
one timestamp), and a vendor-research re-run:
`diff-vendor-seed` reports **0 disagreements and 0 contested tuples** across 1349 obs and 453
base facts, with 88 + 65 new real facts — see `VENDOR-PRICE-RESEARCH.md`.

**Third dump, 2026-08-19 — after item 14's fix, one supply vendor and one alchemy window.** It
closed items 2, 3 and 11 together, exactly as the plan above predicted once the bug eating that
data was gone. Counts in item 14.

**Still wanted:** one Finder search on the merged build, which is all item 4's `statKeys` needs
to become visible.

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

- **Item 3:** whether 30g51s99c per flask is *right*. **Narrowed to one reagent, 2026-08-19:**
  the craft cost reproduces exactly from real data, and `Essence of Earth x2` is 69g of the
  91g56s. Whether 34g50s each is a real market price is an auction-house question, not an addon
  one.
- ~~**Item 2:** whether the *weapon* vellum's name is in the candidate list, and whether both
  vellums price from a vendor rather than the auction house.~~ — **closed 2026-08-19.** Both
  names are in the price database and both candidate names match; both vellums are vendor-sold
  at 2g40s (`52510`, `52511`) and now price from there instead of the AH's 6g85s / 3g22s.
- **Item 6 (built, needs one in-game check):** whether Ascension's recipe tooltips carry the
  stock `ITEM_SPELL_KNOWN` ("Already known") string, and whether class 9 of
  `GetAuctionItemClasses` is Recipe here. If either is wrong the filter hides nothing and
  nothing else changes — search recipes with the option on and see whether known ones drop out.
- ~~**Item 11:** whether the profession harvest stores transmutes at all~~ — **closed
  2026-08-19.** It did not, and the item-link theory was wrong: the window harvest dropped every
  recipe producing an item because its file never captured `zc` (item 14). After the fix,
  `Arcanite Bar` is stored as `id = 12360, made = 1, reagents = Thorium Bar x1 + Arcane
  Crystal x1`. Transmutes harvest fine and the client's links were never the problem. Decides only whether the Sell tab and bag
  tooltips know an `Arcanite Bar`'s craft cost with the profession window closed; the trade
  skill window is correct either way. `/atrprofsort transmute` now prints the link.
- **Item 8:** ~~what `AUCTIONATOR_PRICE_DATABASE` actually retains~~ — **answered 2026-08-19:
  a current price, no series.** 5267 entries of one plain number each, and the mean database's
  8898 samples carry no timestamps. The advisor is a data-plumbing project before it is a
  feature.
- **Item 9:** parked by the owner until item 7 lands.
- **Item 12:** how many item names on this server carry more than one variant. **Part 1's
  blocker is answered** (3 trailing-space rows, no twins — see the item), but the wider question
  is not: the texture test caught 3 in 5267 and misses gear, which is the case that was
  actually reported. The answer decides how much part 3 is worth, not what shape it takes —
  that is settled (variant-in-value, not a re-key).
