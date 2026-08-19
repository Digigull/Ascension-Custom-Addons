# Auctionator — request backlog

Owner's request list, recorded 2026-08-19 before any work starts. This file is the queue and
the record of what each item actually means against the code as it stands; it is not a design
doc. When an item is built, its findings go in a proper per-topic doc (the way
`VENDOR-PRICE-RESEARCH.md` did) and the row here shrinks to a link.

Nothing below has been implemented. Nothing below has been tested in-game — every "current
behaviour" note is read from source, not observed.

Anchors are `file:line` at the time of writing and will drift; the symbol names next to them
are the durable part.

---

## 1. SELL tab — drop the header icon, keep the title, move the hover

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

---

## 2. Enchanting profit is missing on the trade skill window

**Asked:** enchanting profit on the tradeskill window is not working.

**Current behaviour.** The trade skill profit column comes from `Atr_ProfSort_RowProfit`
(`AuctionatorFinderProfession.lua:376` (`Atr_ProfSort_RowProfit`)):

```
sell = Atr_GetAuctionPrice(<recipe row name>)
cost = Atr_ProfSort_RowCost(i)
if sell is nil or <= 0 -> return nil   -- row shows nothing and sinks to the bottom
```

The lookup key is the **trade skill row's name**, which for enchanting is the *enchant*
(`"Enchant Bracer - Superior Stamina"`). What is sold on the auction house is the *scroll*
(`"Scroll of Enchant Bracer - Superior Stamina"`). The price DB is name-keyed, so the enchant
name never matches a scroll listing and `sell` comes back nil for every enchanting row —
which is exactly the reported symptom, and it would hit *all* enchants, not some.

Corroborating: `Auctionator.lua:6114` already knows the two names differ — it shortens
`"Scroll of Enchant"` to `"SoE"` for display.

Second, weaker suspicion, to confirm while fixing: enchanting rows have no produced *item*,
so `GetTradeSkillItemLink(i)` returns an **enchant** link rather than an item link on a stock
3.3.5 client. That does not affect `RowProfit` (which prices by name) but it does affect the
background harvest `Atr_Craft_Harvest` (`AuctionatorFinderProfession.lua:39`), which requires
an item ID from that link and silently skips the row when it can't get one. So enchanting is
probably absent from `AUCTIONATOR_CRAFT_RECIPES` too, and the Sell tab's Crafted Goods Margin
filter never sees it either.

**Likely fix shape.** Try the row name, then `"Scroll of " .. rowName`, then the enchant's
scroll item if we can resolve one. Worth doing as a named helper both `RowProfit` and the
harvest can use, rather than a `string.format` at the call site — the same mismatch will come
back for any craft whose row name is not its product name.

**Unverified.** Whether Ascension names its scrolls the same way stock 3.3.5 does. Confirm
in-game with one known enchant before writing the mapping.

---

## 3. Multi-output crafts price wrong (Distilled Flasks makes 3)

**Asked, twice in the list:** some crafts produce multiple items — Distilled Flasks makes 3
per craft — and profit is off. If the yield can't be recognised reliably, let the user type a
per-craft yield on the trade skill window, defaulting to 1.

**Current behaviour.** The yield is already read and already divided out, in both paths:

- `Atr_Craft_Harvest` (`AuctionatorFinderProfession.lua:58`) stores `made` from
  `GetTradeSkillNumMade(i)`, and `Atr_Craft_GetCraftCost` divides the reagent total by it
  (`:145`).
- `Atr_ProfSort_RowCost` (`AuctionatorFinderProfession.lua:344`) reads `GetTradeSkillNumMade`
  live and divides the same way (`:369`, `math.floor(total / made)`).

Both take only the **first** return of `GetTradeSkillNumMade`, which is `minMade`; the second
is `maxMade`. Both clamp `< 1` up to 1.

So if the profit is off by exactly 3x on Distilled Flasks, the cause is upstream of our
arithmetic: `GetTradeSkillNumMade` is returning 1 (or nothing) for that recipe on this client.
That is the thing to verify first, and it is cheap — add the yield to the `/atrprofsort`
diagnostic output and read it off a live Alchemy window.

**Decided (owner, 2026-08-19): add the diagnostic first, and do not build the manual box until
it has been read in-game.** Three outcomes, and only one needs the box:

1. `GetTradeSkillNumMade` returns 3 → our maths is right and the error is elsewhere
   (most likely the reagent price, or the produced item's own auction price). Re-open.
2. It returns `1, 3` (min 1, max 3) → take `max`, or the midpoint. One-line fix, no UI.
3. It returns `1, 1` or nils → the client genuinely does not expose it. **Then** build the
   manual override.

The diagnostic itself: `/atrprofsort` already exists
(`AuctionatorFinderProfession.lua:735`) and already walks the open profession, so this is a
few added `add(...)` lines, not a new command. Print both returns of `GetTradeSkillNumMade`
per row, separately — the whole question is whether the second differs from the first, and
today's code reads only the first — alongside the cost and sell price it derived.

**If the manual override is built:** a small numeric box on the trade skill window, applying
to the selected recipe, default 1, persisted per recipe (by produced item ID, falling back to
recipe name — enchants have no item ID, see item 2) in a new account-wide saved variable. Read
it as an override *before* `GetTradeSkillNumMade` in both `Atr_ProfSort_RowCost` and
`Atr_Craft_Harvest`, so the Sell tab's margin filter agrees with the trade skill window. An
override of 1 must be distinguishable from "not set", or a user who deliberately sets 1 gets
overwritten by a later correct harvest.

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

## 5. Finder — "My iLvL" should not default on

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

Storage is a new account-wide saved variable with a bounded row count (the Hints DB caps its
raw sample log at 500, `AuctionatorHints.lua:901` — follow that precedent). Decide the cap and
the pruning rule before writing rows, not after the file gets large.

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

## Suggested order

1. **Item 7 (Ledger)** — unblocks 8 and 9, and is the biggest new surface.
2. **Item 3 diagnostic** — one line of `/atrprofsort` output answers whether item 3 is a
   one-line fix or a UI feature. Cheap, and it changes the plan.
3. **Items 1, 5** — small, self-contained UI changes.
4. **Item 2 (enchanting)** — needs one in-game name check, then a helper.
5. **Items 4, 6** — Finder work, independent of each other.
6. **Item 8 (Advisor)** — scope after the Ledger.
7. **Item 9** — investigate with ledger data in hand.

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

- **Item 2:** whether Ascension names enchanting scrolls the stock way
  (`"Scroll of " .. enchantName`). One in-game check against a known enchant settles it.
- **Item 6:** whether Ascension's recipe tooltips carry the stock `ITEM_SPELL_KNOWN`
  ("Already known") string.
- **Item 8:** what `AUCTIONATOR_PRICE_DATABASE` actually retains — a current price, or a dated
  series. The advisor cannot exist without a series, and that answer decides whether item 8 is
  a feature or a data-plumbing project.
- **Item 9:** parked by the owner until item 7 lands.
