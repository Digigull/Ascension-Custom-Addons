# Auctionator — request backlog

Owner's request list, recorded 2026-08-19 before any work starts. This file is the queue and
the record of what each item actually means against the code as it stands; it is not a design
doc. When an item is built, its findings go in a proper per-topic doc (the way
`VENDOR-PRICE-RESEARCH.md` did) and the row here shrinks to a link.

Items marked **DONE** have shipped; the rest have not been implemented. Most "current behaviour"
notes here are read from source, not observed — a shipped item's own section says what was and
was not verified, and which of them have since been confirmed in game (items 2, 3, 11, 14, and
15 + 16 together).

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

### Where the checkbox went

The plan said "next to `Usable`/`My Lvl`". **The control row has no space left**: the search box,
Categories, the level range, three checkboxes and the stat dropdown run from x=72 to x=732 with no
24px gap anywhere, and a second control row would push the results grid down and cost one of the
15 visible rows. It shipped in the **Finder options panel** first, and the owner then looked at it
in game and asked for it on the Finder page after all — **in the header band, above `Group`**,
which a screenshot showed is empty apart from the centred title, and the title ends well to the
left of x=494.

So it is now **both**, mirrored through `Atr_Finder_SetHideKnownRecipes` the same way
`Atr_Finder_SetIgnoreWarn` mirrors its pair. The toolbar checkbox is where you reach for it; the
options row stays because that is where someone reading the option list will look. The toolbar one
is anchored to `Atr_Finder_GroupCheck` rather than placed by absolute offset, so it follows if that
row is ever re-laid-out.

**`Clear` deliberately does not reset it.** It is a persisted preference, not a per-search filter,
and a Clear button silently turning a saved setting back on would be a surprise.

The preference is account-wide (a habit) even though the knowledge is per character.

**Verified in game 2026-08-19** — and this is the item's original open question answered:
**Ascension's recipe tooltips do carry the string.** The owner's per-character file came back with
about **250 entries** in `AUCTIONATOR_KNOWN_RECIPES`, all numeric item IDs, including this
server's own ranges (`967xxx`, `1061xxx`, `100xxx`, `339080`). So the detection works on custom
recipes, not just stock ones, and `GetAuctionItemClasses` index 9 really is Recipe here.

**Not verified in game:** the new toolbar checkbox's placement, which is one screenshot away.

---

## 7. NEW — Ledger: record all purchases and sales — **DONE (v1)**

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

**Scope, answered by the owner 2026-08-19: auction house activity only for v1.** One event
source instead of five, so the Ledger ships in one pass. Concretely v1 records the buy loop's
purchases, the sale/expiry/cancellation mail path and the deposit paid at post time — and leaves
vendor buy/sell and the merchant window alone.

Two things that follow, and both are cheap now and expensive later:

- **The `src` tag ships in v1 anyway** even though only auction-house values are ever written to
  it. It is one field, and adding it later means every existing row has an unknowable source.
- **"Vendor" rows are absent, not zero.** Nothing in v1 should compute a total that silently
  assumes vendor activity did not happen; a report that says "auction house only" is honest,
  one that says "profit" is not.

This item is the prerequisite for items 8 and 9. Build it first.

### Stage 1 shipped 2026-08-19 — the record and two capture points

`AuctionatorLedger.lua`, new file, plus `AUCTIONATOR_LEDGER` account-wide in the `.toc`.

**Deliberately shipped before the UI**, because the two are not equally urgent: a row written
under the wrong schema cannot be back-filled, and a row *not written at all* is simply gone. Rows
accumulate from the moment this loads, so by the time the tab exists there is something in it.

**Captured now:**

| `src` | Where from | What it means |
|---|---|---|
| `buy` | the buy loop, at `PlaceAuctionBid` (`AuctionatorBuy.lua`) | the INTENDED purchase — the only moment the listing is addressable as `("list", i)` |
| `post` | multi-sell confirmation, both the success and the early-stop path (`Auctionator.lua`) | what actually went up, with the deposit |

**The post capture has to be two halves**, and this is the part that would be got wrong on a
second attempt: `CalculateAuctionDeposit` reads the *sell slot*, so the deposit is only knowable
at click time — but whether the auctions were really created is only known when the multi-sell run
reports its last stack. So `Atr_Ledger_NotePostIntent` notes the deposit at the click and
`Atr_Ledger_RecordPost` commits the row at the confirmation. An intent that never gets confirmed is
overwritten by the next one, so a failed post leaves no row.

**Row shape**, following the four rules this item settled before any code:
`t` (raw `time()`), `src`, `who`, `name`/`link`/`id`, `qty`, `unit` (copper, per item — never a
total), plus `deposit`/`stacks`/`stackSize` on a post. The delivered side stays **nil** on a buy:
what arrives is item 9's question and a copy of the intended value would be a lie that looks like
data.

**Cap: 2000 rows, oldest first, and it says so once** in chat when it starts pruning. Not the mean
database's random eviction. Roughly three months of heavy trading, ~240 KB serialised — real but
bounded, and small beside what item 13 measures in the same file.

**Reading it before the tab exists:** `/atrledger` prints totals and the last rows, `/atrledger 40`
more of them, `/atrledger clear` empties it.

**Verified** by `luac5.1 -p` and by an offline smoke test of the row shape under stubs — it checks
that the unit price is derived from the stack total rather than the price sought, that the item ID
resolves, that the delivered side stays nil, that a post's deposit is multiplied by the stacks
that actually posted **and cannot leak into a later post that noted no intent**, and that the cap
drops the oldest row while keeping the newest and warns exactly once. **Not verified in game.**

### Still to come

### Stage 2 shipped 2026-08-19 — the mail side

The ledger now learns what came **back**: `Atr_Ledger_SweepInbox` plus its own debounced event
frame in the same file.

| `src` | From |
|---|---|
| `won` | `Auction won: %s` — the item you bought actually arriving. **This is item 9's delivered side.** |
| `sale` | `Auction successful: %s` — with the invoice's bid, buyout, deposit and auction-house cut kept apart, which the header's lump of money cannot be |
| `expire` | `Auction expired: %s` |
| `cancel` | `Auction cancelled: %s` |

`Outbid on %s` is deliberately ignored — it returns your own bid and is not a trade. Subjects are
matched from the client's own globals (`AUCTION_WON_MAIL_SUBJECT` and friends) exactly as item 6
reads `ITEM_SPELL_KNOWN`, so a localised client still matches; the English literal is the last
resort.

**Counting is a multiset diff, and it has to be.** The owner's own Open All log shows **three
identical `Auction won: Linen Cloth` mails from one seller**, so a content-derived identity cannot
be a set — two real mails would collapse into one row. Each sweep builds the multiset of auction
mails currently in the inbox; a key seen *more* times than last sweep gained that many mails and
those become rows, a key seen *fewer* times lost mails to Postal, which is not an event. The
previous multiset is persisted **per character** (an inbox is), because an unread mail is still
sitting there after a relog and must not be counted twice.

**The first `MAIL_INBOX_UPDATE` after the mailbox opens is swept immediately**, everything after
it debounced at 0.3s the way `AuctionatorFinderMerchant.lua` debounces its harvest. That ordering
is deliberate: Postal starts taking on its own timer, and a debounced first pass could miss
whatever it removed in the meantime.

**Known gap:** a mail that arrives *and* is taken between two sweeps is invisible. Realistically
that is a mail landing while you stand at the box, not a mail from before you opened it.

**Verified** by `luac5.1 -p` and an offline smoke test that replays the owner's actual case
against a fake inbox: five `Auction won` mails with three from one sender produce five rows; three
further sweeps with nothing taken produce none (the update storm); Postal taking them one at a
time produces none; a later visit with the same unread mail still there produces none, while a
genuinely new one produces exactly one; and a sale keeps its invoice parts. **Not verified in
game**, and the event wiring specifically is not covered by that test — it was run with
`CreateFrame` nil, so what is proven is the sweep and the counting, not the frame that calls them.

### Stage 3 shipped 2026-08-19 — the tab

**Own panel on its own main tab**, not a sub-tab. The shared Auctionator panel is built around one
scanned *item* (`FRAMEWORK.md` §4, World 1) and a ledger is not about an item, it is about you —
so the Current/History strip was the wrong home for it however much cheaper it looked.

That means the 15-site main-tab wiring, all tagged **`-- LEDGER_TAB`** so
`grep -n LEDGER_TAB Auctionator.lua` is the census the next person gets, exactly as the Bazaar
left one behind.

**The name was freed first.** Tab 2 of the Current/Ledger strip is renamed to **History**
(`Auctionator.xml:1004`) — it shows the price history of the scanned item, which is what
`Atr_ShowHistory` already titles its own column, so the label was the odd one out rather than a
casualty of this change.

**The panel**: newest first (a ledger is read from the end), a `FauxScrollFrame`, an item tooltip
on any row that still carries a link, and a totals line.

Two things in it are deliberate rather than incidental:

- **The money column states a direction.** A sale reads `+`, a purchase `-`, and expiry and
  cancellation move no money at all so they read `--` rather than zero. A ledger that shows a sale
  and a purchase in the same colour is worse than one that shows neither.
- **The totals line says "auction house", never "profit".** v1 does not see vendor sales, so a
  profit figure would be wrong by exactly the amount the user cannot see. The panel also carries
  the sentence outright: *"Auction house activity. Vendor sales are not recorded yet."* That is
  this item's "absent, not zero" rule made visible rather than left in a doc.

**One layout trap worth keeping:** sibling frames draw in creation order, so the `FauxScrollFrame`
is created **before** the rows. The other way round the scrollbar covers the money column and the
rows stop taking mouse. The row width and the money column both stop short of the bar's ~26px.

**Verified** by `luac5.1 -p`, XML parse, and an offline check of the display maths — that the
newest-first indexing (`rows[n - (offset + i - 1)]`) reads the newest row at the top and pages
correctly, and that the totals add up the three sources separately.

**Verified in game 2026-08-19, and it verified stages 1 and 2 with it.** The owner's screenshot
shows the tab live with twelve rows: **six `Bought` and six `Received`, quantities matching pair
for pair** (x14, x20, x20, x20, x3, x11). So the buy capture, the mail sweep's multiset counting
against a real Postal Open All, the tab wiring and the display all work — and incidentally that
run of Linen Cloth arrived exactly as ordered, which is the first real data point against item 9.

One layout fix from the same screenshot: the "Vendor sales are not recorded yet" note sat at the
panel's left edge, running along the top of the auction house's character portrait. It is now
centred under the title, anchored to the title itself so it follows if that moves.

### Left for v2

- **Vendor buy/sell and mail beyond the auction house** — the scope the owner deferred. The `src`
  tag already exists to carry them.
- **A mail that arrives and is taken between two sweeps** stays invisible (stage 2's known gap).
- **Item 9 is now answerable**: `buy` rows carry what the loop intended, `won` rows what actually
  arrived. Nothing compares them yet — that comparison is item 9's own work.

## 8. NEW — Analysis tab (was: Advisor)

**Asked, originally:** "Ore is up go mine, crafting profit good make this..."

**Rescoped with the owner 2026-08-19**, once items 7, 12 and 13 had settled what data exists.
It becomes its own main tab called **Analysis**, and the owner's own idea leads it:

> "Track how many different named sellers are selling a given item. If in say two hours the user
> scans again and the same seller has sold the item, give it some more weight as a fluid item.
> Still holding the item is more stale rating. This has been something I have wanted to know for
> some time to help understand better items to farm."

**That is the right instinct and nothing else in this addon can answer it.** Price says what an
item is worth; it says nothing about whether anyone is buying. An item at 50g that moves once a
week is worse to farm than one at 5g that moves twenty times a day, and no price database can
tell those apart.

### The data is already being collected

- **`owner` is stored per listing** — `AtrScan:AddScanItem` keeps `sd["owner"]` today.
- **`GetAuctionItemTimeLeft` is already called** — the Finder reads `rec.timeLeft` for its Time
  column (1=Short, 2=Medium, 3=Long, 4=Very Long).

So a listing can be fingerprinted as `owner + stackSize + buyout` and diffed across scans without
any new capture. What is missing is retention and the arithmetic.

### The refinement that makes it rigorous: sold vs expired

A listing that vanishes has not necessarily sold — it may have expired or been cancelled, and
counting those as sales would inflate every number on the tab. **`timeLeft` separates them.**

A listing seen with **Long or Very Long** remaining that is gone at the next scan cannot have
expired in that window, so it was bought or cancelled — overwhelmingly bought. One that vanishes
from **Short** most likely expired. That single distinction turns "turnover" from a vague feel
into a defensible sales estimate, and it costs nothing because the field is already read.

### Candidate features

**A — Turnover and liquidity (the core; nothing else in the addon does this)**

| | Feature | Notes |
|---|---|---|
| A1 | **Seller depth** — distinct sellers per item | how contested the item is |
| A2 | **Listing turnover** — fingerprint listings, diff across scans | vanished vs still held, the owner's original idea |
| A3 | **Sold vs expired**, from `timeLeft` | what makes A2 an estimate rather than a guess |
| A4 | **Seller concentration** | one seller holding 80% of supply is a different market from ten sharing it — they can move the price at will, and they will notice you |
| A5 | **Median listing lifetime** | "time to sell" |
| A6 | **Undercut churn** — how often the lowest price changes | high churn means active competition, and a thin margin |

**B — What to farm and craft (the original ask)**

| | Feature | Notes |
|---|---|---|
| B1 | **Farm score = estimated sales rate x unit price** | gold per unit time. **This is what "items to farm" actually means**, and A1–A3 are what make it computable |
| B2 | **Recipe profit ranking** | already computed by `Atr_ProfSort_BuildOrder`; needs surfacing, not building |
| B3 | **Reagent pressure** | which reagents your profitable recipes need, and whether those are liquid enough to buy |

**C — Price trend (needs a dated series; see the note below)**

| | Feature | Notes |
|---|---|---|
| C1 | **Now vs history** | the literal "ore is up" ask |
| C2 | **Volatility band** | is 30g normal for this item or an outlier |
| C3 | **Price/turnover quadrant** | dear and liquid is the sweet spot; cheap and stale is the trap |

**D — From the Ledger (item 7 already records this)**

| | Feature | Notes |
|---|---|---|
| D1 | **Realised margin per item** | what you actually paid against what you actually got — the only number here that is not an estimate |
| D2 | **Sell-through rate** | of what you listed, how much sold versus expired |
| D3 | **Capital tied up** | gold sitting in unsold listings, plus deposits burned |

**E — Scope and plumbing**

| | Feature | Notes |
|---|---|---|
| E1 | **Watchlist of items or categories** | the owner's suggestion, and it is also what bounds the storage problem |
| E2 | **Scan freshness** | every number above decays; the tab must say how old its evidence is |
| E3 | **Retention policy** | decided before the first row is written, as with the Ledger |

### Honest limits, to design around rather than discover

- **Disappeared is not sold.** `timeLeft` narrows it and never proves it. Everything in group A is
  an estimate and the tab should say so — the same "absent, not zero" rule the Ledger follows.
- **Only what you scan.** `getAll` is disabled on this server, so coverage is whatever you
  searched. This is why E1 is not optional: the watchlist is the unit of analysis.
- **Turnover is a FLOOR, not a count.** Anything posted and sold between two scans is invisible.
  Two scans two hours apart cannot see a third listing that lived twenty minutes.
- **Rates must be per elapsed time, not per scan.** Scan cadence is irregular and user-driven, so
  "3 sold since last scan" means nothing without the interval.
- **`owner` can come back nil** — `AtrSearch:ProcessBatch` already counts `numNilOwners` — so
  seller-count arithmetic needs a rule for unknown owners rather than treating them as one seller.

### v1 shipped 2026-08-19

`AuctionatorAnalysis.lua`, `AUCTIONATOR_ANALYSIS` account-wide, and an **Analysis** main tab
(15 sites tagged `-- ANALYSIS_TAB`). Built: **A1, A2, A3, A4, B1, E1, E2** — seller depth,
listing turnover, the sold/expired split, seller concentration, the farm score, an item watchlist
with groups, and scan freshness.

**It needs no scanner of its own.** Every Finder result row already carries `owner`, `count`,
`buyoutPrice` and `timeLeft`, so one guarded hook in `Fdr_AnalyzeResults` feeds it and a watched
item accumulates from ordinary searching.

**Watchlist by individual item, with named groups** (owner's choice — categories would blur the
per-item turnover the farm score is built on). Items are added by typing a name or shift-clicking
a link into the box; groups are free-text and the dropdown filters by them. `/atranalysis add`
does the same from chat.

#### The cadence effect, which the build surfaced rather than hid

The sold/expired rule is: a listing gone from bucket B could not have expired if less than B's
minimum remaining life has elapsed. That makes precision **a function of how often you scan**,
not of the market — a Very Long listing is only a certain sale if you look again within 12 hours,
a Long one within 2.

A test case caught what that means in practice: with a **24-hour** gap, two listings that
disappeared from Very Long came back as *ambiguous*, not sold — correctly, since they could have
expired. Scan twice a day and almost everything is ambiguous; scan every couple of hours, which is
exactly the cadence the owner described, and the ambiguity collapses.

So the farm score is a **range**: the low end counts only provable sales, the high end also counts
the ambiguous ones. Showing the low end alone would read as "nothing sells here" for anyone who
scans slowly — a statement about them, not about the item. Ranking uses the upper bound, because
for a slow scanner the lower bound is zero for everything and a ranking where everything ties is
no ranking.

**Verified** by `luac5.1 -p` and an offline test of the classification: a listing vanishing with
12h+ left counts as sold; one vanishing from Short never does; the same Long listing counts as
sold after 1 hour and ambiguous after 3; three identical listings from one seller are counted
rather than set-merged (the Ledger's mail lesson, applied); rates are per elapsed day; a 10-day
gap accumulates no observed time at all; and unwatching forgets the history. **Not verified in
game.**

#### Still to come

B2/B3 (recipe ranking, reagent pressure), C (price trend — needs the dated series), D (the Ledger
views, nearly free now), A5/A6 (listing lifetime, undercut churn).

### Original v1 suggestion, for the record

**A1 + A2 + A3 over a watchlist, with B1 as the headline number.** That is the owner's own idea,
made rigorous by the `timeLeft` distinction, answering the question they actually asked ("what is
worth farming") — and it is self-contained: no price series, no new capture, only retention and
arithmetic over data the scan already produces.

C needs the dated series and can follow. D is nearly free whenever the tab exists, since the
Ledger already holds it.

### On the price series (C), for when it is wanted

The machinery already exists and is tested: `Atr_AddHistoricalPrice`, `ToTightTime` /
`FromTightTime`, and `Atr_Condense_History` already keep a dated series — they are simply pointed
at **your own postings** rather than at the market. Feeding them market prices is a writer and a
retention rule, not a new subsystem.

**The naive version does not fit**, though: 5771 names x one sample a day x 30 days is ~170,000
entries, several megabytes, immediately after item 13 clawed back 384 KB. A watchlist of 20–50
items at a daily close for 90 days is ~4,500 entries and about 100 KB. Another reason E1 comes
first.

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

**Item 7 has landed, and this stays parked (owner, 2026-08-19)** — deliberately, until a case
that reproduces consistently turns up. That is the right call: one remembered sighting cannot be
debugged, and guessing at it would mean building a comparison against a bug nobody can trigger.

**What changed anyway is that the waiting is now productive.** The ledger records both halves
without being asked: a `buy` row carries what the buy loop *intended* — item, stack, unit price,
at the moment it issued `PlaceAuctionBid` — and a `won` row carries what the mail *delivered*.
The first real run through it (2026-08-19, six purchases of Linen Cloth) matched pair for pair,
x14/x20/x20/x20/x3/x11 on both sides, which is what a healthy purchase looks like in this data.

So when it happens again the evidence will already be sitting in `AUCTIONATOR_LEDGER`, and the
question becomes a query rather than an investigation: find a `buy` row whose `won` counterpart
names a different item. **Nothing needs to be built to keep collecting it.** What is not yet
written is the comparison itself — pairing buys to their deliveries is this item's own work, and
it should be written against a real mismatched pair rather than an imagined one.

Worth knowing when that day comes: pairing is not trivial. The mail carries no reference to the
auction it came from, so buys and deliveries can only be matched on item, quantity and time
order — and a Postal Open All delivers a batch at once, which is exactly when the ordering is
least reliable.

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

1. ~~**Split the scan buckets on something that works**~~ — **DONE 2026-08-19, option B.** See
   "Part 1 as built" below.
2. ~~**Give the Sell tab the item it was actually handed**~~ — **DONE 2026-08-19, and the
   mechanism was not the one written here.** See "Part 2 as built" below.
3. ~~**Teach the price database about variants.**~~ — **DONE 2026-08-19 for the auction price
   database.** See "Part 3 as built" below. The MEAN database is the remaining half.

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

**Recommendation: B**, and **the owner chose B (2026-08-19)**. It is the only one that leaves the
database in the shape part 3 is designed to extend, and its arbitrariness is bounded — one of two
real prices for a name, where today you also get one number for a name. A is a silent price
increase, which this addon should never do. C is work that part 3 deletes.

**The three existing trailing-space rows** need no migration under any option: none has an
unsuffixed twin, so they answer no lookup and shadow nothing. Stripping the space and adopting
the value would give three items a price they currently lack — a small win, worth doing in the
same pass, not worth a `__dbversion` bump.

**Deferred to part 3, deliberately:** recording each row's link in `AddScanItem`. It costs a
`GetAuctionItemLink` per listing across a full scan, and nothing reads it until the database can
store a variant. Doing it now would buy nothing and slow every scan.

### Part 1 as built (2026-08-19) — option B

Owner chose **B** from the three options above: keep the item's real name on the scan, carry the
variant in the *lookup key*, so a split can never invent a database row.

**The split is on QUALITY.** It comes free from `GetAuctionItemInfo` in the batch loop and it
separates the reported rare/epic pair. Deliberately **not** on level: Ascension scales gear per
instance, so listings of one item carry many required levels and a level split would shatter
every gear row into dozens of buckets.

**What it replaces:** a texture comparison that never fired where it mattered, because variants
share an icon. Measured on the real database — 3 splits in 5267 entries, all recipes or a
container, **none on gear**, which is the case that was reported.

**The implementation is smaller than option B sounded**, because the separation already had a
natural home. `Atr_FindScan` was doing two jobs with one argument: keying `gAllScans` *and*
naming the scan. Splitting that argument in two —

```lua
Atr_FindScan (scanKey, init, itemName)   -- itemName defaults to scanKey
```

— means a variant bucket is `gAllScans["Name#q4"]` while its `scn.itemName` stays `"Name"`. So:

- **No UI change was needed.** Roughly fifteen call sites read `activeScan.itemName` for the
  recommendation text, the sell header, the search summary, posting and the undercut popup. They
  all still get a real name. Had the variant gone in `itemName` (the first way I wrote it) every
  one of them would have printed `Bloodforged Imperial Jewel#q4`.
- **No finaliser change was needed** either: `gAtr_ScanDB[scn.itemName]` is already the real name.
  Two buckets of one name both write it and the last wins — no worse than the single merged
  number it wrote before, and it is what part 3 extends.
- **The two rows distinguish themselves for free.** Each bucket calls `UpdateItemLink` with its
  own listing's link, so each gets its own `itemTextColor` — the rare row renders green and the
  epic row purple under one name, which is the honest picture.

**One trap found while writing it:** the primary bucket's quality has to be *adopted from the
first listing of this search*, not stored at creation, because `AtrSearch:Init` seeds that bucket
before the loop runs and `Atr_FindScan` hands back a scan object reused from an earlier search.
`AtrScan:Init` now clears `variantQuality`, and the loop adopts it on first sight; without both
halves a stale quality from a previous search would split the very first listing.

`scn.texture` is left in `Init` as a vestige and marked as one — nothing else ever read it.

### The old rows are retired at load

`Atr_RetireVariantSpaceKeys` (`Auctionator.lua`, called from `Atr_InitScanDB`) strips the
trailing-space keys the old hack wrote. Where the real name has no row the value is **adopted**
— it is a real observed price and the alternative is that item having none; where both exist the
real name wins untouched. Run every load rather than behind a migration flag: once the rows are
gone it is one pass that finds nothing, and no `__dbversion` bump is needed.

**Verified against the owner's real 5471-entry database** (not reasoned — the shipped function
was extracted and run over the actual saved variables):

```
price DB: 5471 -> 5471 entries        mean DB: 5471 -> 5471 entries
removed 3   ["Plans: Splintering Staff ", "Plans: Effigy of Overgrowth ",
             "Duskrune Chopper Cache (Backsheath) "]
adopted 3   (the same three, unsuffixed)
no other row mutated;  trailing-space keys left: 0
```

**Still not verified in game**, and this is the part to watch: the split itself has only been
reasoned. The check is to search a name with two qualities on the auction house and confirm two
rows appear, coloured by their own quality, and that the price database afterwards still holds
one row for that name.

**Deferred to part 3, deliberately:** recording each row's link in `AddScanItem`. It costs a
`GetAuctionItemLink` per listing across a full scan and nothing reads it until the database can
store a variant.

### Part 3 as built (2026-08-19)

Built to the recommended shape below, unchanged: the key stays the **name**, the **value** carries
the variants, and a legacy number simply *is* "one variant, unknown id" — so there is no
`__dbversion` bump, no rewrite pass and no risk of eating anyone's database.

```
gAtr_ScanDB[name] = 123456                       -- legacy: one price, untouched
gAtr_ScanDB[name] = { ["52510:0"] = 97500,       -- itemId:suffixId
                      ["52511:0"] = 1233375,
                      ["?"]       = 97500,       -- price for the name, variant unknown
                      dflt        = 97500 }      -- derived: the lowest of them
```

Three functions in `AuctionatorHints.lua`, beside the pricing cascade that owns this:
`Atr_VariantKey(link)`, `Atr_PriceValue(value, variantKey)`, `Atr_PriceStore(db, name, price,
variantKey)`.

**Every reader and writer now goes through them** — 16 sites audited, in `AuctionatorHints.lua`,
`AuctionatorScan.lua` (both the targeted finaliser and the full scan), `AuctionatorFinderPriceDB.lua`
and `AuctionatorBazaar.lua`. The **walkers were the ones that mattered** and the item said so in
advance: `Atr_GetAHVariantEstimate` and `/atrprices` reset both filtered on
`type(price) == "number"`, which after this change would have **silently skipped exactly the rows
the database knows most about**. Both now resolve the value instead.

**Only one writer knows its variant, and that is enough.** After part 1 the targeted scan's buckets
each carry their own listing's link, so that finaliser writes the variant slot. The full scan, the
Finder feed and the Bazaar aggregate by name with no per-variant link, so they write the
name-level slot exactly as they always did.

#### The bug the test caught, which is the part worth remembering

`dflt` is **derived, never assigned**: the minimum across every slot. Written the obvious way —
legacy value into `dflt`, then `dflt` recomputed from the variant slots alone — the first variant
written to a legacy row **threw the old price away**, and a name-only lookup jumped to whatever
variant happened to be scanned first. On `Bloodforged Imperial Jewel` that was 97500 → 1490000.

**A price rising quietly is the worst thing this database can do to someone pricing their goods**,
and it is exactly the failure that ruled out option A in part 1. The fix is the reserved slot
`ATR_PV_ANY` (`"?"`) — a price for the name with the variant unknown — which the variant-less
writers keep refreshing, so it is a live value rather than a ghost.

**And the rule it settled on was wrong too, caught the same way.** `dflt` was the minimum across
every slot, which reads well and mixes eras: a variant slot is only refreshed when that exact name
is targeted-scanned, while `ATR_PV_ANY` is refreshed by every full scan and by the Finder feed. So
one stale cheap variant would pin a name's answer below the market indefinitely with nothing to
lift it back.

The owner's first post-change dump had a live example before it could do any harm —
`Large Fang = { ["5637:0"] = 9900, ["?"] = 11000 }`, where the minimum rule answered 9900 for the
name while the current name-level price was 11000. **`dflt` is now `ATR_PV_ANY` when it is set,
and only falls back to the lowest variant when it is not**, which also makes a name-only lookup
behave exactly as it did before variants existed, since that slot is written by precisely the
writers that used to write the bare number.

Two shape bugs in one small function, both found by running it over a real database and neither
by reading it. That is the lesson worth keeping from this item.

That bug was **not caught by reasoning about it**; it was caught by running the shipped functions
over the owner's real 5471-row database. Worth doing again for anything that touches this table.

**Verified** against that database: all 5523 rows read back identically through `Atr_PriceValue`;
variant keys parse off real links including a random-suffix one (`7909:1614`); a dearer variant
added to **every row in the database** raised the name-only price on **none** of them; an unknown
variant key falls back to the default; and the walker still resolves every row after promotion.
**Not verified in game.**

#### Remaining: the mean database

`gAtr_MeanDB` is still name-keyed and merged, so on a name with two variants the tooltip's
`Auction` line is now variant-aware while `Auction median` is not — the two can disagree, which
this item predicted. It is a bigger change than it looks, because a mean row is an *array of
samples* rather than a number, so the same trick needs a shape that nests one. Deliberately left
for its own pass rather than doubling this one's blast radius; **fold item 13's single-sample
change into it**, since both rewrite that value's shape.

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

## 13. NEW — a third of the saved-variables file is redundant — DONE

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

### Both trims shipped 2026-08-19, together with item 12 part 3b's decision

**Trim 1 — the seed echo.** `Atr_VendorSeed_DropEchoes` runs at `PLAYER_LOGOUT` and
`Atr_VendorSeed_Merge` puts them back at `PLAYER_LOGIN`. No new machinery was needed: the merge
was already idempotent and already documented as safe to run every login, so this is simply its
inverse.

**The rule is "only what the seed will put back identically", checked against the seed's own value
rather than trusted from the flag.** A seeded entry that has since been confirmed by a real sale
is a field-tested fact, not an echo — `diff-vendor-seed.lua` reports those separately for exactly
this reason — so an entry is dropped only when the shipped seed holds the same price and nothing
has been learned on top. That makes the round trip provably lossless rather than probably.

**Trim 2 — the one-sample shape.** A mean row holding a single sample is now a bare number and
only becomes a table on the second. `Atr_MeanAppend` creates the right shape on first write,
`Atr_MeanMedian` reads either, and `Atr_CompactMeanDB` folds what is already on disk at load.
The full scan's habit of **pre-creating an empty table for every name it saw** was the source of
most of them, and is gone.

**Measured on the owner's real database:**

| | before | after |
|---|---:|---:|
| vendor `obs` entries | 1437 | **99** |
| vendor `base` entries | 518 | **78** |
| mean rows that are tables | 5523 | **1967** |

1778 vendor entries dropped and 3556 mean rows folded — about **384 KB of a 1.14 MB file, a third
of it**, and the login merge restored `obs` and `base` to exactly 1437 and 518 with **zero prices
changed**.

**Verified** by replaying both round trips over the real saved variables: every median identical
across compaction, a folded row promoting correctly on its next sample, and the vendor tables
restored entry-for-entry and price-for-price by the merge as the addon actually runs it.

**Verified in game 2026-08-19**, on the first dump taken after the migrations ran:

| | expected | actual |
|---|---|---|
| vendor `obs` / `base` after the logout trim | 99 / 78 | **99 / 78** |
| mean rows still holding a single-element table | 0 | **0** |
| trailing-space price keys | 0 | 0 |

All 2462 single-sample mean rows are bare numbers and every remaining table holds two or more.
The file itself grew — 1.14 MB to 1.30 MB — because that session scanned a great deal more
(5523 → 5771 names, 10882 → 13656 samples, plus the ledger); without the two trims the same
content would have been roughly 1.6 MB.

The same dump carried the **first variant rows written in game**, which is item 12 parts 1 and 3
working end to end: `Wool Cloth` and `Large Fang` both hold a variant slot beside their
name-level one.

### Item 12 part 3b: the mean database is deliberately NOT variant-aware

Part 3 left this as the remaining half, on the grounds that a variant-aware `Auction` line and a
name-level `Auction median` can disagree. **The data says not to do it.**

This database holds **1.97 samples per name**: 64% have exactly one and only 8.7% have five or
more. Splitting that by variant leaves most variants with a single sample — a "median" of one
number — so it buys no statistical accuracy at all, while turning one value into three shapes
(number, sample array, variant map) and touching every reader again.

The mild inconsistency between an exact `Auction` line and a name-level `Auction median` is the
cheaper of the two wrongs. Recorded in `Atr_GetMeanPrice`'s own comment as well, so the next
person to have this idea finds the measurement before the code.

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

## 15. SELL tab — the sell pane could keep the wrong same-name variant — DONE

**Reported 2026-08-19** as a clean differential: dragging a Bloodforged item into the sell box got
the **epic** correctly, while clicking the *same item* in the SELL tab's inventory browser got the
**blue** one.

**Then it flipped.** After a few more attempts the owner saw the reverse — the drag path picking
the rare. That single observation is what solved it, and it invalidated the first write-up of this
item, which had confidently named `Atr_ClearAll` and a premature `Atr_UpdateUI` in the click path
as the difference.

**A bug that swaps sides is not one path being wrong. It is an ordering race.** Two code paths
that disagree consistently point at the paths; two that trade places point at the state they
share.

### The race

`Atr_OnNewAuctionUpdate` opens with:

```lua
if (not gAtr_ClickAuctionSell) then
    gPrevSellItemLink = nil;
    return;
end
gAtr_ClickAuctionSell = false;
```

The flag is **consumed by the first `NEW_AUCTION_UPDATE`** and every later one early-returns. Item
12 part 2's identity correction lives further down, inside the block guarded by
`gPrevSellItemLink ~= auctionLink` — so it runs only when the flag-carrying event is also the one
that sees a changed link.

How many of those events the client fires, and which of them carries the flag, differs between
dropping an item in the box and clicking a tile — and, as the flip proved, between attempts on the
same path. Whichever variant the cached scan happened to hold then stayed.

### The fix

`Atr_Sell_SyncScanIdentity` (`Auctionator.lua`), called at the **top** of
`Atr_OnNewAuctionUpdate`, before the flag check, so it runs on every one of these events rather
than only on the one that wins the race. It reads the sell slot, and if the active scan is about
that item but holds a different link, pushes the real one in through `AtrScan:UpdateItemLink` and
marks the pane for repaint.

Two properties make an unconditional call safe:

- **Name-guarded.** When this runs the active scan may still be the PREVIOUS item's — `DoSearch`
  has not necessarily happened yet — and pushing this item's link into that scan would corrupt it.
  A scan that is not about this item is left completely alone.
- **Idempotent.** It returns early when the link already matches, so firing on every event costs
  one comparison after the first.

Item 12 part 2's original correction after `DoSearch` stays: it is the one that runs on a *fresh*
scan, where this helper would have nothing to compare against yet.

**Verified** by `luac5.1 -p` and an offline test of the helper's guards: a scan holding the wrong
variant of this item is corrected and the repaint requested; a second call writes nothing; a scan
for a different item is untouched; an empty sell slot, a missing scan and a missing pane are all
no-ops; and the identity ends correct under every ordering of flagged and unflagged events — which
is the race itself.

**Closed in game 2026-08-20, together with item 16.** This fix was necessary but not sufficient —
it corrected the identity the sell pane *starts* with, while item 16's bugs overwrote that
identity again later in the same search. Both were in play, and the symptom only went away with
both fixed, so neither can claim the in-game result alone.

**What to watch:** the symptom was intermittent, so one successful drag or click proves nothing.
Load the epic and the rare alternately, by both paths, several times each.

---

## 16. SELL tab — an epic sell item turned blue as its own search completed — DONE

**Re-reported 2026-08-20**, after item 15 shipped: the SELL tab searches a Bloodforged epic and
shows it **blue**; search it again and it comes back **purple**, correctly. Searching something
else and coming back a few times gets it blue again.

Item 15 was not wrong, it was **incomplete**. It fixed the identity the sell pane *starts* with.
This one is the identity being **overwritten again, later, by the scan itself** — which is why the
symptom survived a fix that provably corrects the sell slot's link, and why a second search
(inside the 20 s rescan window it is a cache hit, so no batch runs) showed the right colour.

### Two bugs in the batch loop, and both need the other

`AtrSearch:AnalyzeResultsPage` (`AuctionatorScan.lua`) walks a page of listings, buckets them by
quality (item 12 part 1), then ends each iteration with what was, verbatim:

```lua
if (scn.itemLink == nil or self.itemClass == nil) then
    scn:UpdateItemLink (GetAuctionItemLink("list", x));
end
```

`self` is the **AtrSearch**. `itemClass` is a field only **AtrScan** has — a search has never
carried one — so `self.itemClass == nil` is **always true** and the guard never guarded anything.
Every listing rewrote its bucket's identity, so a bucket ended up describing whichever listing it
happened to see **last**, and `UpdateItemLink` also writes the shared name-keyed link cache, so
every listing poisoned that too. A rare listed after the epic recoloured the epic on the spot.
This is upstream's line, not the fork's; the quality split is what gave it teeth, because before
that the overwriting links at least all belonged to one bucket.

Fixing only that is not enough, because of the second bug: the **primary bucket adopted the
quality of the first listing it saw**. So on an auction house that lists a rare first, the epic's
own name-keyed bucket *becomes the rare's*, all the epic's listings go to a `#q4` side bucket —
and the sell pane keeps showing the primary one. Blue name, and blue **prices**, on an epic.
`Atr_OnSearchComplete` only re-points `activeScan` when a search yields exactly one scan, which
after a split it does not, so nothing downstream corrected it either.

That is the whole reported behaviour, including its intermittency: **it depends on the order the
auction house returns the two variants in**, which is not stable between searches.

### The fix

Three lines of behaviour in `AuctionatorScan.lua`:

- **Bucket the primary scan by the item it is ABOUT, not by listing order.**
  `scn.variantQuality = scn.itemQuality or quality`. By the time a batch lands, the sell path has
  already pushed the real sell item's link in (item 12 part 2 pushes it right after `DoSearch`,
  which is the only `DoSearch` the sell slot ever triggers, and item 15's helper re-asserts it on
  every `NEW_AUCTION_UPDATE`), so `scn.itemQuality` **is** the variant in the player's hands.
  The old first-listing behaviour survives as the fallback for a scan that has no link — a cold
  cache, and all a browse search ever has.
- **Take a listing's link only when the bucket needs one**: no link at all, or a link whose
  quality is not this bucket's. The second case is real and is why the test is not just
  `itemLink == nil`: a **variant** bucket's `Init` can only look its name up in the same
  name-keyed cache, so it starts out holding the *other* variant's link. Both cases are
  self-limiting — once the link matches the bucket, it stops firing.
- **`AtrScan:Init` now clears `itemQuality`** alongside `itemLink`. It never did, so a reused scan
  whose link could not be resolved answered with the previous item's quality — harmless while
  nothing read the field, load-bearing now that the bucketing does. `AtrSearch:Finish` reads
  `scn.itemQuality + 1`, so that read is now nil-safe.

### Why this one got a test when the house rule says not to build harnesses

Because the symptom has now escaped twice, and because the cause is **listing order** — the exact
thing reading the code kept getting wrong, in both write-ups. So the orders are enumerated instead
of reasoned about: `management/addons/auctionator/tools/sell-variant-smoke.lua`, 27 assertions,
run from the repo root under bare `lua5.1`. It stubs only what that loop touches and must not grow
into a client emulator.

Against the **pre-fix** source it fails 7 of 27, and fails them *only in the rare-listed-first
order* — the epic-first order passes untouched. That asymmetry is the intermittency, reproduced.
Against the fix, 27/27.

**Verified** by `luac5.1 -p` and that test.

**Verified in game 2026-08-20 — this item is CLOSED.** The owner could not reproduce the
recolouring after the merge, having tried the sequences that used to bring it back reliably.
That is the right shape of evidence for this one: the bug was intermittent and order-dependent,
so a single clean search would have proved nothing, and "the tricks that used to trigger it no
longer do" is the strongest statement the symptom allows.

**What to watch:** the sell pane now shows the epic's **prices** as well as its name, so a
Bloodforged epic with no epic listings up will correctly report no current auctions rather than
quietly quoting the rare's. That is the intended change, not a new bug.

---

## 17. Analysis tab — fed by every search, and able to scan on its own — DONE

**Asked 2026-08-20:** the Analysis tab only updates from the **Finder**, not from a **Buy** tab
search; the UI needs adjusting; and a **refresh scan** button on the tab itself would help.

### Why only the Finder fed it

Because the Finder is the only scanner that keeps `timeLeft`. The tab's whole method rests on it:
a listing that vanished between two scans was *bought* only if less time passed than its last-seen
countdown bucket guaranteed it had left (item 8). The Finder's result rows already carry owner,
stack, price **and** time-left, so wiring it up was one call.

Every other search — Buy, Sell, More — runs through `AtrSearch:AnalyzeResultsPage`, and that loop
reads `GetAuctionItemInfo` but never `GetAuctionItemTimeLeft`; what it keeps
(`AtrScan:AddScanItem`) is stack, price, owner and page. So there was nothing downstream to feed
the analysis *with*, which is why the Finder was special.

### The feed

`Atr_An_CollectListing` is called from that loop, for **watched items only**, and reads the
time-left the loop never bothered with. The listings are **banked on the search** and handed over
in `AtrSearch:Finish`, not observed per page — because *a listing that is absent is what "sold"
means*, and observing half a scan would report every listing on the pages not yet fetched as
bought. That mistake would land in a saved database, indistinguishable from real sales
afterwards.

So completeness is asserted, never assumed. `anComplete` is set **only** where the batch loop
finds a short page — the server had nothing more to give. Three routes to `Finish` deliberately
leave it false and discard the bank:

- the **too many results** early-out (>3000 on page 1),
- the **duplicate page** bail (>10),
- the two **watchdogs** in `Atr_OnUpdate`, which finish a stalled search with pages outstanding.

A fourth guard is about the query rather than the scan: a **level-filtered** compound search
(`Atr_ParseCompoundSearch` returning min/max level) returns a *subset* of an item's listings, and
on this server that is not hypothetical — gear scales per instance, so one item's listings carry
many required levels. Those outside the filter would read as sold, so such a search is not
observed at all.

The result is broader than asked: **any** completed search feeds the tab, so ordinary Sell-tab
and More-tab scans count too. That is the same rule, not a wider one — a complete result set for
a watched name is a valid observation whichever tab asked for it.

### The Rescan button

Watching an item and then having to remember to go and search for it is the wrong way round, so
the tab now has a **Rescan** button: one exact search per watched item in the current group, run
in sequence, with progress beside the button and a second click to stop.

It drives `gAnalysisPane` through the **ordinary search machinery** rather than calling
`QueryAuctionItems` itself. One pump owns the auction API; a second racing it is how duplicate
pages and disconnects happen. The cost of that choice is real and is stated in the button's
tooltip: the pump only advances the **current pane's** search, so leaving the tab stops the run
(`Atr_An_OnTabClick` cancels it rather than leaving a half-run wedged).

Each item is searched with `rescanThreshold` **0** — never accept a cached scan. A cache hit
would re-observe the previous scan's listings, comparing a snapshot against itself: zero sales,
and elapsed time added for nothing.

**One trap worth recording:** the obvious "is this tab being pumped" test — `gCurrentPane ==
gAnalysisPane` — silently never fires. `gCurrentPane` is a **file-local** in `Auctionator.lua`
(line 204) and reads as nil from another file, while `gAnalysisPane` happens to be a global. The
selected tab is what assigns `gCurrentPane` in the first place and *is* readable, so
`An_TabIsCurrent` asks `Atr_IsTabSelected (ATR_ANALYSIS_TAB)` instead.

### The UI

The headers and the row cells were two separate lists of coordinates and had drifted apart:

- every header sat at the **left edge** of a column whose value was centred or right-aligned, so
  nothing lined up with its own heading;
- **Low**'s right edge (606) sat under the **Gold/day** header (610);
- **Gold/day**'s cell ran to 656, under the per-row delete button;
- the summary line — three sentences — was a `FontString` with no width, so it ran off the panel.

Both are now generated from **one** `AN_COLS` table, which is what stops them drifting again; the
delete button has its own lane past the last column; and the summary has a width and wraps
upward. Rows also gained the Ledger's item tooltip on hover, from the shared link cache.

**Verified** by `luac5.1 -p` and a new offline test,
`management/addons/auctionator/tools/analysis-feed-smoke.lua` (17 assertions): the sold-vs-expired
attribution end to end, unwatched items costing nothing, and the three guards above — a full page,
a level-filtered query and a second `Finish` on the same search each observe nothing. Removing
either the completeness or the level guard fails it, which is how we know they are load-bearing
rather than decorative. `sell-variant-smoke.lua` still passes 27/27 over the same batch loop.
**Not verified in game.**

**What to watch:** the layout numbers are reasoned from the Ledger's budget (columns end at 630,
delete button 636–656, scroll bar owns 664+), not seen. *(Superseded 2026-08-20 — item 23: they
were wrong, and wrong in exactly this way. The budget is Blizzard's 768px auction house; Ascension's
is wider, so the table stopped a third short of the right edge. Widths are now measured at init and
the columns share out the slack, so no coordinate here is a constant any more.)* And a rescan of a large watchlist is one
AH query per item — cancellable, but not quick.

---

## 18. Getting items onto the watchlist (and the shopping list) from where you find them — DONE

**Asked 2026-08-20:** a plain "this is an estimate" tooltip on **Sold/day** and **Gold/day**; a
**right-click menu on the Finder** to add an item to a shopping list or an Analysis group; and a
**button under the item icon on the Buy tab** to add it to an Analysis group.

### The tooltips

Two lines, on the column headers. A `FontString` cannot take scripts, so a column carrying a `tip`
in `AN_COLS` gets an invisible hit frame over its header — 16px tall, stopping above the scroll
frame at -92 so it cannot swallow a click meant for a row.

- **Sold/day** — *An estimate. Counted from listings that disappeared between two scans, so it is
  a floor, not an exact count.*
- **Gold/day** — *An estimate: Sold/day valued at the current lowest price. A rate, not a promise.*

### The right-click menu — which is also a bug fix

Finder rows have always called `RegisterForClicks ("LeftButtonUp", "RightButtonUp")`, and
`Fdr_Row_OnClick (self, button)` has always **ignored `button`**. So a right-click ran the entire
left-click path: jump to the Buy tab, open the group window, or **ask to buy that listing**.
Giving the button a meaning of its own removes that.

The menu offers *Add to shopping list* and *Add to Analysis group*, each as a submenu. Both are
"remember this"; neither is "buy it now", which is what makes them the right pair for a right-click
on a row whose left-click buys. It is also safe mid-scan — nothing it does changes tabs or cancels
a scan, which the left-click path has to refuse.

The **group window**'s rows (opened from a multi-listing row) got the same menu. They only
registered `LeftButtonUp`, so right-click there did nothing at all; every listing in that window is
the same item, so filing it works exactly as it does outside.

### Where the code lives, and why

One menu serves the Finder and the Buy tab: `Atr_An_ShowItemMenu (anchor, itemName, withShoppingList)`
in `AuctionatorAnalysis.lua`. It is there because the **groups** are there, and it reaches the
shopping lists through two new functions in `AuctionatorShop.lua` — guarded by name, so neither
feature depends on the other:

- `Atr_Shop_UserLists()` — the lists a user can actually file into. **"Recent Searches" is excluded
  on purpose**: it is a rolling log this addon rewrites, so anything filed there would not survive.
- `Atr_Shop_AddNameToList (index, name)` — enforces the same 50-item cap the *Add Item To List*
  button does, and reports *why* it declined (`already`, `full`) so the menu can say so instead of
  failing silently.
- `Atr_Shop_CreateListWithItem` backs a **New list...** entry, without which the branch is useless
  to anyone who has no custom lists yet. **New group...** does the same on the other side.

Picking a group for an item that is **already watched moves it** — `Atr_An_Watch` updates the group
and reports that it added nothing — which is what picking a group off a menu ought to do.

### The Buy tab button

A small **Watch** button under `Atr_RecommendItem_Tex`, opening the group half of the same menu.

It is created in `Atr_An_Init` but parented to the icon's own parent and anchored to the icon, so
it stays put if that strip ever moves. The band below the icon is empty: the recommend text and
prices all sit at x >= 109, and the auction list starts at y -213.

~~Show/hide is the part worth knowing. It is `recommendElements[8]`, so it hides everywhere that
strip hides. What membership cannot express is **"Buy tab only"** — the strip is shown on SELL as
well — so `Atr_An_UpdateBuyButton` runs immediately after `Atr_ShowElems (recommendElements)` in
`Atr_ShowCurrentAuctions` and takes it back unless we are on Buy with an item.~~

**Superseded — this was wrong, and the button never appeared. See item 19.** The recommend strip
is the SELL tab's; the Buy tab *hides* it. Membership therefore meant "hidden on every Buy tab
repaint".

**Verified** by `luac5.1 -p` and by the two existing offline tests still passing (17 + 27), which
cover the batch loop and the analysis feed this touches around. The menu itself is UI and the two
list rules are three lines each, so **no new harness** — the house rule, deliberately applied.
**Not verified in game.**

**What to watch:** dropdown menus are the one bit of 3.3.5 API here that cannot be checked offline
— `ToggleDropDownMenu (1, nil, frame, "cursor", 0, 0)` for the right-click and the button frame as
the anchor for the Buy tab. And the Watch button's position is reasoned from the XML offsets, not
seen.

---

## 19. The Buy tab's Watch button never appeared — and a second button beside it — DONE

**Reported 2026-08-20** with two screenshots, which is what made it quick: item 18's **Watch**
button was nowhere on the Buy tab. And a companion request — an **add to shopping list** button
there too.

### Why it never appeared

Item 18 made the button `recommendElements[8]`, reasoning that it would then "hide wherever that
strip hides". The strip is `Atr_Recommend_Text`, the two prices, and the icon.

**That strip is the SELL tab's recommendation, and the Buy tab explicitly hides it.** In
`Atr_UpdateUI`:

```lua
if (Atr_IsModeCreateAuction()) then     -- SELL
    Atr_UpdateRecommendation (false);   -- ... shows the strip
else
    Atr_HideElems (recommendElements);  -- BUY and MORE: hides it
    ...
    Atr_ShowItemNameAndTexture (...)    -- then paints its own header
```

So membership meant *hidden on every Buy tab repaint* — the exact opposite of the intent — and the
one place that showed the strip again (`Atr_UpdateRecommendation`, where the correcting call was
placed) only ever runs on SELL.

The Buy tab's header is `Atr_ShowItemNameAndTexture`, which **re-shows two members of that hidden
strip by hand**: the icon, and `Atr_Recommend_Text` *reused as the item's name*. That reuse is the
detail the first attempt missed — the strip is not one thing that is either up or down, it is a
SELL widget set that Buy borrows two pieces of.

### The fix

The buttons are **not** in `recommendElements`. `Atr_An_UpdateBuyButton` is called from the three
places that paint or leave that header, and it decides:

| Call site | Tab | Result |
|---|---|---|
| `Atr_ShowItemNameAndTexture` | Buy paints its item header | shown, when an item is up |
| `Atr_UpdateRecommendation` | SELL paints its recommendation | hidden |
| the tab click, after `Atr_HideElems` | anything else | hidden |

The third exists because a tab whose header never repaints would otherwise inherit whatever the
Buy tab left visible.

**Also fixed while there:** the Buy tab's *search summary* view calls the same header function with
the search text, and its pane still carries a scan — one that `Atr_FindScan (nil)` names the
literal string `"nil"`. The visibility test now uses `AtrScan:IsNil()`, so the buttons do not offer
to watch an item called "nil".

### Placement, corrected by the screenshot

Item 18 put the button under the **icon**, on the reasoning that the band there is empty. It is
not: the **Back** button sits there whenever a search matched more than one item, which is the
common case (the screenshot was a "silk" search). Both buttons now anchor under
`Atr_Recommend_Text` — the item's name on this tab — which is clear on Buy. What occupies that
space on SELL is the two recommended prices, and these are hidden there.

### The second button

**Add to List**, beside Watch, opening the shopping-list half of the same menu.

It is not a duplicate of the panel's existing *Add Item To List*: **that one adds whatever is in
the search box**, so searching `silk`, opening `Silk Cloth` and pressing it files *"silk"*. This
one files the item you are looking at, and asks which list.

`Atr_An_ShowItemMenu`'s third argument became a mode — `"both"`, `"groups"`, `"lists"` — rather
than a boolean. A button that already says what it does gets its choices **flat**; only the
Finder's row menu, which offers both destinations, needs submenus.

**Verified** by `luac5.1 -p` and the two offline tests (17 + 27) still passing. The failure this
item fixes was a UI-visibility rule spread across three files, which no offline test in this repo
could have caught — the honest answer is that the screenshot caught it, one round later.
**Not verified in game.**

---

## 20. The Buy tab's buttons opened no menu — and the labels — DONE

**Reported 2026-08-20:** the two buttons from item 19 now appear, but clicking either does
nothing. Plus two cosmetic asks: swap their positions, and rename them **+Shopping list** and
**+Analysis**.

### Why nothing opened

The buttons appear only when `Atr_An_BuyItemName()` returns a name, and the click handler asks the
same function — so the click *was* reaching `Atr_An_ShowItemMenu`. That put the fault inside the
dropdown call, not around it.

**This addon already contains a context menu that works**: the Finder's **Categories** button
(`Atr_Finder_CatDDMenu`, `AuctionatorFinder.lua`). Comparing the two, item 18's version differed in
exactly two ways, and both are the bug:

```lua
-- what works                                 -- what item 18 did
local catDD = CreateFrame (...)               gAnMenu_Frame = CreateFrame (...)
catDD:Hide();                                 -- (never hidden)
UIDropDownMenu_Initialize (catDD, init, "MENU");
catBtn:OnClick = function (self)              function ...
    ToggleDropDownMenu (1, nil, catDD, self, 0, 0)   UIDropDownMenu_Initialize (frame, init, "MENU")   <-- every click
end                                               ToggleDropDownMenu (1, nil, frame, anchor, 0, 0)
```

**`UIDropDownMenu_Initialize` runs the init function immediately.** Calling it on every click meant
the menu's buttons were built against whatever `UIDROPDOWNMENU_MENU_LEVEL` and
`UIDROPDOWNMENU_MENU_VALUE` the last dropdown anyone opened had left behind — and
`UIDropDownMenu_AddButton` places a button by comparing its level against that global. Any level but
the one about to be shown, and the buttons go where nobody is looking. `ToggleDropDownMenu` sets
those globals itself and *then* calls the init function, which is why initialising **once at
creation** is not a tidiness point but the entire mechanism.

The menu's content still varies per click: the init function reads `gAnMenu_Item` and
`gAnMenu_Mode` at the moment Toggle calls it, and those are set just before.

The second difference — the frame never being `:Hide()`n — leaves a stray dropdown widget parented
to `UIParent` at the screen origin. Not the reported symptom, but wrong.

**Also fixed:** toggle means toggle. With one menu already open, clicking the *other* button closed
the first and opened nothing — a third way to look like a dead button. `CloseDropDownMenus()` first
when a list is up.

**And the anchor:** `"cursor"` is gone; both call sites now anchor to the frame that was clicked,
which is what the Categories button does. The Finder's right-click menus hang off the row.

### The general lesson, which is why this is written down

Two rounds were lost to the same shape of mistake: **reasoning from how an API ought to work
instead of from a working example twenty lines away in the same addon.** Item 19 was
`recommendElements`; this one was the dropdown lifecycle. When this client's UI API is involved,
find the call in this repo that already works and copy its shape exactly — the differences that
matter are rarely the ones that look meaningful.

### Labels

Swapped, and renamed as asked: **+Shopping list** (100px) sits under the item name, **+Analysis**
(76px) to its right.

**Verified** by `luac5.1 -p` and the two offline suites (17 + 27). Neither can reach a dropdown, so
this rests on matching a known-good call in the same client. **Not verified in game.**

---

## 21. The menu is no longer a Blizzard dropdown — DONE

**Reported 2026-08-20, second time:** item 20's fix landed, the labels are right, and clicking the
buttons *still* does nothing.

### Why stop debugging it

Item 20's diagnosis was sound as far as it went — initialising a dropdown on every click really is
wrong, and the Finder's Categories button really is the working recipe. It did not fix the symptom.

`UIDropDownMenu` is driven by four globals — `UIDROPDOWNMENU_MENU_LEVEL`, `_VALUE`, `_OPEN_MENU`,
`_INIT_MENU` — that **every other dropdown in the UI writes**, including Blizzard's own and any
other addon's. A menu that ends up on the wrong level, or against a stale open-menu name, does not
error: it silently draws nothing. That is a bad thing to depend on from here, because **no offline
check in this repo can reach any of it**, so every attempt costs a full round trip through the
client to learn one bit.

Three rounds is the answer to "how many guesses is an opaque API worth".

### What replaced it

About 90 lines of plain frame in `AuctionatorAnalysis.lua`: a backdrop, one row button per entry,
and a full-screen click-eater behind it. No shared globals, no initialise/toggle lifecycle, nothing
another addon can perturb.

- **The eater cannot outlive the menu.** It covers the screen, so a stuck one would leave the UI
  unclickable. The menu's `OnHide` hides it — that is the single point of truth, rather than every
  close path remembering.
- `FULLSCREEN_DIALOG`, frame level 10, **not toplevel** — deliberately opened, must clear the
  auction house, and that strata is near-empty. See `DRAG-FREEZE.md` for why toplevel is never the
  answer.
- It flips above the anchor when there is no room below, so a Finder row near the bottom of the
  list does not drop its menu off the screen.
- Submenus are gone. The Finder's menu shows both sections one after the other with headers — a
  flat list of eight is easier to hit than two fly-outs, and there is no submenu machinery left to
  get wrong.

### The part that is now testable

Splitting "what is on the menu" from "how it is drawn" made the first half a pure function,
`Atr_An_MenuEntries (itemName, mode)`, returning `{ text, func, disabled, header }`.
`analysis-feed-smoke.lua` grew ten assertions over it (17 → 27): every group appears, the empty
shopping-list case still offers a way in, `both` is the two sections plus headers, no item means no
menu — and the entries' `func`s really watch and really move an item between groups.

The frame is still beyond reach. But the half that was ever likely to be wrong in a *content* sense
is now checked in a second, and the half that remains is code with no hidden dependencies.

### One diagnostic, deliberately

`/atranalysis menu [item name]` opens the same menu with no button in the way.

The house rule puts an in-game debug command last, so the reason is recorded here: from outside the
client, **"the click never fired" and "the menu never showed" look identical**, and that ambiguity
is exactly what cost rounds 19–21. This separates them in one step. If the buttons stay dead but
the command works, the fault is the button's `OnClick`, not the menu.

**Verified** by `luac5.1 -p` and the two offline suites (27 + 27). **Not verified in game** — but
unlike the last two attempts, what is left to be wrong is code in this repo rather than a global
this repo cannot see.

---

## 22. The dead Buy-tab buttons — a frame level, all along — DONE

**Reported 2026-08-20, third time.** Item 21 replaced the Blizzard dropdown with our own frame and
the buttons still do nothing. The owner's question — *could they be drawing behind the AH UI?* — is
a good one, and it is checkable: this addon's own dialogs (`Atr_Error_Frame`, `Atr_Confirm_Frame`,
`Atr_Buy_Confirm_Frame` and five more) are all `FULLSCREEN_DIALOG` parented to `UIParent`, exactly
what the menu now is, and those have always been visible over the auction house. So strata alone
does not explain it.

### Why this item is instrumentation and not a fourth fix

Every remaining explanation produces the **identical** report from outside the client:

| What is really happening | What the owner sees |
|---|---|
| the click never reaches the button | nothing happens |
| the click fires, the menu is never built | nothing happens |
| the menu is built and shown somewhere invisible | nothing happens |

Three rounds have now been spent picking one of those by reasoning and shipping a fix for it. The
cost of a wrong guess is a full round trip through a client this repo cannot run; the cost of
measuring is one command.

### What it adds

- **Three counters on the buttons** — `hovered`, `clicked`, and whether `Atr_An_ShowItemMenu`
  returned true. `hovered` is the important one: it is set by the tooltip's `OnEnter`, so it
  answers *does mouse input reach this button at all* without the owner having to describe what
  they saw.
- **`/atranalysis diag`** — prints those counters, then `shown / visible / strata / level /
  mouse-enabled / position / size` for both buttons, the menu, the click-eater, `AuctionFrame` and
  `Atr_Main_Panel`, plus what `GetMouseFocus` currently reports.

One run of that command decides between all three rows of the table above, and the position and
size lines settle the behind-the-UI question outright.

The house rule puts an in-game debug command last. This is last: it is the fourth report of the
same symptom, and the third mechanism tried.

### The one candidate fix shipped alongside

The buttons now sit at **frame level + 20** within their panel. If something in that panel shares
their strata at a higher level, it takes the mouse first and the click never arrives — the top row
of the table. It is a frame *level*, not a `Raise()` and never toplevel (`DRAG-FREEZE.md`), it is
what the strata table in `management/docs/CLAUDE.md` prescribes for exactly this, and it costs
nothing if it was never the problem.

**If the buttons work after this**, that was the cause and this item closes as a fix. If they do
not, the diag output says which of the three rows it is, and the next change is aimed rather than
guessed.

### It was the frame level

**Confirmed in game 2026-08-20:** the buttons work. The diagnostic never had to be read — the
candidate fix shipped beside it was the answer, which is the top row of the table: **the click was
never reaching the button.** Something else in `Atr_Main_Panel` shares its strata at a higher frame
level and was taking the mouse first. The buttons were drawn (that is why they were visible and
looked fine) but were not the frame under the cursor.

Worth naming plainly, because three fixes were aimed at the wrong half of the problem: **items 20
and 21 were both fixing the menu, and the menu was never broken.** The evidence available at the
time — a button that renders correctly and does nothing — reads as "the thing the click opens is
broken", and it was not. Nothing in the menu code needed to change; the two rewrites were paid for
the lesson only.

That said, item 21's rewrite is kept and is not wasted: the dropdown's four shared globals really
were an untestable dependency, and the menu that replaced it has its contents under offline test.

### The rule this produced

The first `/atranalysis diag` printed to chat, and **chat cannot be selected on this client** — so
its output could only have come back as a screenshot. That is now a repo-wide rule in
`management/docs/CLAUDE.md`: in-game debug output goes into a copy/paste window, never chat.
`Atr_An_ShowDebugBox` in `AuctionatorAnalysis.lua` is this addon's implementation (the pattern
comes from `PassLootBiS_Scanner`'s `/plbisscan debug` box, which had already learned it), and
`/atranalysis diag` now uses it: `FULLSCREEN_DIALOG`, dark backdrop, multi-line `EditBox`, text
pre-selected so **Ctrl+C** is the only key needed.

The diag stays. It cost nothing to keep, the next unexplained UI failure gets it for free, and it
is now in a form whose output can actually be pasted back.

---

## 23. Analysis tab — the layout assumed a 768px auction house — DONE

**Asked 2026-08-20, with a screenshot:** the Add box is too big and sits under the character
portrait; the columns leave the right third of the tab empty; Rescan is not at the right; the
column headers are crowded from above; and the yellow paragraph under the table should go.

Four of the five are one root cause. Every number in `Atr_An_Init` was reasoned from **Blizzard's**
auction house — 768px wide, so a 738px panel and a 660px row (item 17's "What to watch" note said
as much: *reasoned from the Ledger's budget, not seen*). **Ascension's window is wider than that.**
Everything anchored to the panel's `BOTTOMRIGHT` therefore stopped short of the real right edge
with a band of empty backdrop past it, which is what put Rescan in the middle of nowhere, and the
columns ended where a 660px row ended rather than where the table does — so the two money columns
were squeezed hard enough to **wrap onto two lines** while ~90px of table sat unused beside them.

The fix is to stop naming a width:

- the panel measures `AuctionFrame:GetWidth()` at init and spans the backdrop exactly
  (`frameW - 22`, since the panel starts 10 in from the left and the backdrop ends 12 in from the
  right), so a `BOTTOMRIGHT` anchor is genuinely bottom-right. Fallback 768 if the frame has no
  width yet;
- the scroll frame, `AN_ROW_W` and the columns all derive from that;
- `AN_COLS` entries carry a **minimum `w` and a `grow` weight** instead of a fixed `x`;
  `An_LayoutCols(rowW)` fills in `cx`/`cw`, handing the slack out by weight and giving the rounding
  remainder to the last growing column so the row's right edge lands exactly on the delete lane.
  Weights: Item 3, Group 1, Sold/day 1, Low 2, Gold/day 2, the two counts fixed. On a ~830px
  window that is Item 184→216, Low 84→105, Gold/day 88→111.

The other two:

- **the Add box** is half its old width (180→90) and starts at x=76 rather than x=24. The portrait
  is a 60px texture at the window's top-left, so anything under panel x≈57 is behind a face — the
  label at x=20 and the box at x=24 both were. Its `Add` button and the group controls follow it.
- **the headers** moved from -74 to -84, and the scroll frame and rows from -92 to -102, with them.
  The group dropdown's frame art hangs well below its own anchor and was all but touching the
  header row.
- **the yellow paragraph** is gone; the summary is now just `N watched`. The two clauses it carried
  are the same two facts the `Sold/day` and `Gold/day` header tooltips already state (item 18) —
  which is where someone puzzled by a number looks — so as standing text it was a wall of yellow
  under the table that never changed.

**Verified** by `luac5.1 -p`, `analysis-feed-smoke.lua` (27/27, it loads the file), and by running
`An_LayoutCols` standalone at 768, 830 and an absurd 600: at the two real widths the columns end
exactly on the delete lane, and at 600 they fall back to their minimums rather than inverting.
**Not verified in game** — the widths are now measured rather than assumed, which is the point,
but nothing here has been seen on screen.

### Follow-up, same day, from a screenshot of the result

The above shipped and the tab was **screenshotted in game**, which settled two things the reasoning
had not.

**Gold/day still wrapped onto two lines.** Not a width problem — a *content* problem.
`zc.priceToMoneyString` always ends on copper and pads every coin with two trailing spaces, and
Gold/day can print a **range**, so `279g 10s 31c-310g 28s 78c` ran past twenty glyphs. Analysis now
has its own `An_Money`: gold and silver, single-spaced, no trailing pad (which on a right-aligned
cell had been holding the number off its own right edge). Under a gold it prints silver; under a
silver it prints copper, because dropping it *there* would leave the cell blank rather than coarse.
The rest of the addon keeps `zc.priceToMoneyString` — this is a table of estimates, not a receipt.

**A FauxScrollFrame's bar hangs OUTSIDE the scroll frame.** It is anchored to the frame's
`TOPRIGHT` at x=+6, so the lane it needs comes off the *panel*, not off the rows. Reserving it
inside as well — rows were `scrollW - 30` — spent it twice, which is why a band of backdrop
survived to the right of the delete buttons in the screenshot. Rows are now the full scroll width,
`AN_SB_LANE` (26) is reserved beyond it and 4 more keeps the bar off the backdrop's edge. Worth
~12px, no more: what is left at the right edge **is** the bar's lane, and it has to stay reserved
or the bar lands on the delete buttons the moment the watchlist passes 14 rows. The Ledger reserves
the same lane twice and is untouched.

Column budget retuned with the space that freed: Sold/day 68→80 minimum and grow 1→2, Gold/day
88→96 and 2→4, Low's grow 2→1. The two that can print a range are the greedy ones; Low never can.

**Verified** by `luac5.1 -p`, both smoke tests (27/27 each), and by loading the real `An_Money` and
`An_LayoutCols` straight out of the file under bare lua5.1 — `An_Money` against the exact values in
the screenshot (`984g 49s`, `279g 10s`, `37s`, `6g 80s`, and 45 copper still printing as `45c`),
and the layout at 768/830/1024 to confirm the columns end exactly on the delete lane and the bar's
lane clears the last one. Gold/day at a ~830px window is 128px against a ~118px worst-case range.
**Not verified in game.**

---

## Suggested order

Items 1–6, 11, 14, 15, 16, 17, 18, 19, 20, 21, 22 and 23 are **done**, and item 10 closed without any code (2026-08-19). Rewritten
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
- **Item 6:** the toggle goes in the **Finder options panel**, not the control row — that row is
  full (see the item).
- **Item 12 part 1:** **option B** — the scan keeps the item's real name and the variant rides in
  the lookup key, so a bucket split can never invent a price-database row.
- **Item 7:** **auction house activity only for v1.** Vendor and mail are a later pass.

## Still open

- **Item 3:** whether 30g51s99c per flask is *right*. **Narrowed to one reagent, 2026-08-19:**
  the craft cost reproduces exactly from real data, and `Essence of Earth x2` is 69g of the
  91g56s. Whether 34g50s each is a real market price is an auction-house question, not an addon
  one.
- ~~**Item 2:** whether the *weapon* vellum's name is in the candidate list, and whether both
  vellums price from a vendor rather than the auction house.~~ — **closed 2026-08-19.** Both
  names are in the price database and both candidate names match; both vellums are vendor-sold
  at 2g40s (`52510`, `52511`) and now price from there instead of the AH's 6g85s / 3g22s.
- ~~**Item 6:** whether Ascension's recipe tooltips carry the stock `ITEM_SPELL_KNOWN` string~~ —
  **closed 2026-08-19: they do.** ~250 recipes cached on the owner's character, including this
  server's custom ID ranges.
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
