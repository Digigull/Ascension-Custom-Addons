# Auctionator — how the addon is put together

A map of `Auctionator-Finder-Ascension/`, written 2026-08-19 from a structural read of all
29,000 lines, before starting the request backlog (`BACKLOG.md`). Its job is to make the next
change land in the right file without re-deriving the layout each time.

Read `README.md` in the addon folder first — it says what the fork *does*. This says how it is
*built*, and it is deliberately about the seams: what is upstream and what is ours, which parts
share state, and what a new subsystem costs.

Everything here is read from source. Nothing is verified in-game.

**Baseline at the time of writing:** `luac5.1 -p` passes on every file except
`Locales/deDE.lua` and `Locales/esES.lua`, which fail on a UTF-8 BOM and are expected to —
see the repo `CLAUDE.md`. This addon has no offline tests of its own; §9 covers what that
means, and where the repo's existing ones live.

---

## 1. The one-line summary

It is a **fork of Auctionator 2.9.9**, with roughly a third of the code being Ascension-specific
additions that were mostly written as *new files*, plus two blocks that were written *inside*
the upstream monolith. The additions are well-decomposed and heavily commented; the upstream
core is a 6,248-line grab-bag. Almost all of the backlog lands in the additions.

---

## 2. Telling our code from upstream's

There is no upstream remote to diff against — the whole addon arrived in one commit
(`4d09e2a`, "Add files via upload"), so git history cannot answer this. Three reliable
signals, in order of confidence:

**Indentation.** Upstream is tab-indented. The largest local block inside `Auctionator.lua` is
4-space indented, and the boundary is absolute:

| Lines | Content | Tabs | 4-space |
|---|---|---:|---:|
| 1–1000 | upstream head, scroll shims | 79% | 20% |
| 1015–1232 | canvas / frame art (**local**) | 100% | 0% |
| 1233–1568 | tab click handling | 92% | 7% |
| **1569–2721** | **SELL browser + expanded SELL layout (local)** | **0%** | **100%** |
| 2723–6248 | upstream | ~92% | ~7% |

793 consecutive lines of 4-space code in a tab-indented file. That block is already a separate
file in everything but name. (The canvas-art block at 1015–1232 is also local but was written
matching the file, so indentation does not flag it — comment density does.)

**Comment density.** The repo `CLAUDE.md` notes these addons carry unusually heavy explanatory
comments; that is a local habit, not upstream's. Whole-file figures:

```
  73.9%  AuctionatorFinderScanThrottle.lua   ─┐
  54.0%  AuctionatorFinderBuyRedirect.lua     │
  41.7%  AuctionatorFinderMerchant.lua        │ local additions
  30.7%  AuctionatorFinderPriceDB.lua         │
  27.8%  AuctionatorFinderProfession.lua      │
  24.8%  AuctionatorHints.lua                 │ (mixed — see §7)
  17.0%  AuctionatorFinder.lua               ─┘
  13.9%  Auctionator.lua                     ─┐
  12.1%  AuctionatorScan.lua                  │ upstream
   9.0%  zcUtils.lua                          │
   8.4%  AuctionatorShop.lua                 ─┘
```

**Marker comments.** The previous author tagged edits with the feature that motivated them:
`-- FINDER_TAB` (103 sites) and `-- BAZAAR_TAB` (18 sites). A tagged line in an upstream file is
a local edit. **Keep this convention** — §8 shows how much it is worth.

---

## 3. Load order

From the `.toc`, and it is load-bearing in three places:

```
Locales/*.lua          strings only
zcUtils.lua            shared utility namespace (addonTable.zc)
Auctionator.lua        THE CORE — globals, event wiring, panes, SELL, history
AuctionatorShop.lua    Buy tab
Auctionator.xml        all upstream frames
AuctionatorLocalize.lua ZT()
AuctionatorPane.lua    AtrPane object
AuctionatorScan.lua    the scan engine
AuctionatorQuery.lua   query throttling
AuctionatorVendorSeed.lua  GENERATED — never hand-edit
AuctionatorHints.lua   tooltips + pricing API + vendor learning   (see §7)
AuctionatorVendor / Conflicts / API / Config / Buy
AuctionatorFinder.lua          ─┐
AuctionatorFinderPriceDB.lua    │
AuctionatorFinderFullScan.lua   │ the Finder cluster; AuctionatorFinder.lua
AuctionatorFinderOptions.lua    │ MUST load first — it publishes the F surface
AuctionatorFinderBuyRedirect.lua│ that the rest capture at load time (§6)
AuctionatorBazaar.lua           │
AuctionatorFinderScanThrottle.lua
AuctionatorFinderProfession.lua │
AuctionatorFinderMerchant.lua   │
AuctionatorFinderItemCount.lua ─┘
AuctionatorConfig.xml
```

Three ordering facts that will bite if changed:

1. **`AuctionatorFinder.lua` publishes `addonTable.Finder` at line 2788**; the four files that
   read it capture `FT`, `MoneyString` etc. into locals *at load*. Load one earlier and it
   silently captures `nil`.
2. **`AuctionatorFinderBuyRedirect.lua` loads after `Auctionator.lua` and `AuctionatorShop.lua`
   on purpose** — it *replaces* three upstream globals by redefining them, so the later
   definition has to win. It says so in its header. This is the fork's alternative to editing
   upstream files, and it is a good pattern.
3. `AuctionatorVendorSeed.lua` is generated by `tools/gen-vendor-seed.lua`. See
   `tools/README.md` before touching it, and note `meta.built` is load-bearing.

---

## 4. The central fact: there are two UI worlds

**This is the thing to know before touching any Auctionator UI.**

### World 1 — the shared panel (upstream: Sell, Buy, My Auctions)

There is exactly **one** `Atr_Main_Panel`, created once from the virtual `Atr_Sell_Template`
(`Auctionator.lua:2992`, `Auctionator.xml:304`). Every upstream tab shares those same widget
objects. `Atr_AddSellTab` (`:3004`) does **not** create a frame per tab — it creates a tab
button and returns an `AtrPane` *data* object (`AuctionatorPane.lua`). Switching tabs runs
`Atr_HideElems`/`Atr_ShowElems` over the shared widgets.

Everything awkward about the SELL tab follows from this:

- The expanded SELL layout has to **save and restore geometry**
  (`Atr_Sell_SaveGeom` / `Atr_Sell_RestoreGeom`, `:2273`/`:2291`) because it is moving widgets
  another tab will use. `ATR_SELL_GEOM` holds widget *names*, not references, with a comment
  explaining that one `nil` in a table constructor truncates `ipairs` and would silently
  shorten the save list.
- Anything *added* to the SELL column must be per-tab and reversible, which is why the drop
  zone and the Ignore button are built in Lua rather than XML (`:2443`, `:1652`) — both say so.
- `Atr_Sell_ReflowControls` exists because a *hidden* frame still occupies its anchor.

### World 2 — own panel (local: Finder, Bazaar, Ledger, Analysis)

`AuctionatorFinder.lua:3869`, `AuctionatorBazaar.lua:1382`, `AuctionatorLedger.lua` and
`AuctionatorAnalysis.lua` each `CreateFrame` their **own** panel parented to `AuctionFrame`, and
build every widget in Lua. They share nothing with the upstream tabs and need no save/restore
dance.

> **Rule for new work: build in World 2.** New UI gets its own panel, created in Lua, in its own
> file. The four local tabs all did this and none has the SELL tab's problems.
> Only touch World 1 when the change is *to* an upstream tab — which, in the backlog, is item 1
> and nothing else.

The Analysis tab is the furthest this has been taken: **one panel, one table, three views** over
different data (market estimates, the Ledger, the crafting ranking), swapped by Show/Hide rather
than rebuilt. §8 has the recipe.

---

## 5. Where the data lives

19 account-wide saved variables and 19 per-character — every one declared in this fork's own
`.toc`, which is why a dump is a single file (`BACKLOG.md` says why that matters). The ones that
matter:

| Variable | Shape | Written by |
|---|---|---|
| `AUCTIONATOR_PRICE_DATABASE` | `[realm_Faction][name] = lowest per-unit buyout` | Finder scans (`FinderPriceDB`) |
| `AUCTIONATOR_MEAN_PRICE_DATABASE` | `[realm_Faction][name] = { up to 15 sorted samples }` | same |
| `AUCTIONATOR_PRICING_HISTORY` | `[name][timetag] = "price:stacksize"` | **your own postings only** |
| `AUCTIONATOR_CRAFT_RECIPES` | `[itemID or name] = { made, reagents }` | profession windows + recipe tooltips |
| `AUCTIONATOR_NPC_PRICES` | vendor prices | merchant scan |
| `AUCTIONATOR_VENDOR_LEARNED` | `obs` / `base` / `cb` / `log` | vendor sales — see `VENDOR-PRICE-RESEARCH.md` |
| `AUCTIONATOR_FINDER_SETTINGS` | Finder options, plus `statKeys` = set of every stat key ever seen on gear | Finder + options panel |
| `AUCTIONATOR_ITEM_LOCATIONS` | who owns what, where | `FinderItemCount` |
| `AUCTIONATOR_LEDGER` | `{ ver, rows = { {t, src, who, name, link, id, qty, unit, …} } }` — what you bought and listed | `AuctionatorLedger` (BACKLOG item 7) |
| `AUCTIONATOR_ANALYSIS` | `{ ver, watch = {[name]={group}}, groups, obs = {[name]={fp, sold, amb, secs, scans, low, id, …}}, ids = {[name]=itemID} }` — the watchlist and what scanning has learned about it | `AuctionatorAnalysis` (BACKLOG item 8) |

`ids` is the odd one and worth knowing about: a **name → item ID** map, because a tooltip needs an
ID and this tab is full of rows that only have a name (a watch entry, and every enchant recipe,
which is filed under the scroll it sells as). It is *gated* to names the tab can draw, and most
answers never reach it at all — see §6.

### The finding that matters most: there is no market price series

This settled the open question hanging over backlog item 8 (Advisor), and it is worth stating
flatly because three different variables *look* like they might answer it.

**What item 8 did about it: it stopped asking.** The Analysis tab ships without a price series and
without waiting for one — it counts what *disappears* between two scans instead, which is a
question the existing data can answer, and it says out loud that the answer is an estimate. The
series remains unbuilt and remains the blocker for the price-trend features (group C in the
item); everything else in that item was built around it.

**Confirmed on real data, 2026-08-19.** The first genuine dump of this addon's saved variables
holds 5267 price rows of one plain number each, and 5267 mean rows carrying 8898 samples — every
one a bare number in an array, no timestamps anywhere, longest array 14 against the cap of 15.
Read from source, then confirmed from the file:

- **`AUCTIONATOR_PRICE_DATABASE` is current-value only.** One number per item name, overwritten
  on each scan. No history.
- **`AUCTIONATOR_MEAN_PRICE_DATABASE` is undated, and evicts at random.** The write path
  (`AuctionatorFinderPriceDB.lua:174-179`) appends a sample, and once there are 15 it removes
  one at `math.random(1, #m)` and re-sorts. No timestamps, and after the first eviction the
  array is not even a *sequence* — it is a random sample of the past. It cannot be retrofitted
  into a series; the ordering information was never written.
- **`AUCTIONATOR_PRICING_HISTORY` *is* a dated series** — keyed by name, then by a packed time
  tag, with a `Atr_Condense_History` compactor already written. But its only three writers
  (`Auctionator.lua:2793`, `:2812`, `:2880`) all pass `gJustPosted_*`. **It records what you
  listed things at, not what the market did.**

So "ore is up, go mine" is not computable from anything currently stored — not from the code,
and not from a year of accumulated data. The *machinery* for a
dated series exists and is reusable (`ToTightTime`/`FromTightTime` at `:6221`/`:6229`, plus the
condenser); the *market* series does not. That makes item 8 a data-plumbing project first, and
it is the reason the backlog orders the Ledger ahead of it.

---

## 6. The de-facto internal APIs

Three exist. None is declared as such anywhere, which is the main documentation gap.

### The pricing cascade — the most important, and it is duplicated

Four global functions answer "what is this worth":

| Function | Answers | Defined in |
|---|---|---|
| `Atr_GetAuctionPrice(nameOrID)` | lowest scanned AH price | `AuctionatorHints.lua:273` |
| `Atr_GetMeanPrice(nameOrID)` | median of the sample array | `AuctionatorHints.lua:318` |
| `Atr_GetNPCPrice(itemID)` | fixed vendor *buy* price | `AuctionatorFinderMerchant.lua:58` |
| `Atr_GetSellValue(item)` | vendor *sell* value floor | `AuctionatorAPI.lua:24` |

Four functions, three home files, none of them named for pricing. Callers span seven files. The **cascade** — NPC price, then auction price, then vendor floor —
is written out twice, in `Atr_Craft_GetCraftCost` (`AuctionatorFinderProfession.lua:126-140`)
and `Atr_ProfSort_ReagentPrice`, and the second one's comment said it "mirrored" the first. Two
copies of a three-branch fallback that had to agree, or the Sell tab's margin filter and the
trade skill window's profit column would disagree about the same item.

**Collapsed 2026-08-19** into `Atr_Craft_ReagentPrice` (`AuctionatorFinderProfession.lua`),
while building backlog item 2. Every craft-cost path now goes through it. Enchanting adds one
more term on top — a vellum — which is applied by the callers, not the cascade; see the
ENCHANTING block in the same file.

Note also that `AuctionatorAPI.lua` is the *outward* API — it re-exports Tekkub's
`GetSellValue`/`GetAuctionBuyout` for other addons. It is not the internal one.

### The `F` surface — the only real namespace

`AuctionatorFinder.lua:2788` publishes `addonTable.Finder` with `FT`, `MoneyString`,
`GetResults()`, `GetCapHit()`, `Redir`, `GetState()`, `State_NULL`. Adoption is split along
historical lines, and the split is coherent rather than random:

- **Uses `F`:** the files split out *of* `AuctionatorFinder.lua` — PriceDB, FullScan, Options,
  BuyRedirect.
- **Globals only:** the files split out of `Auctionator.lua` or `Hints` — Profession, Merchant,
  ScanThrottle, ItemCount — plus Bazaar and Hints themselves.

602 distinct global functions exist overall. That is upstream's style and it is not worth a
campaign to fix, but **new subsystems should take the `F`-surface route**, which the four newest
files already model.

### One function per view — how the Analysis tab reads everyone else's data

The newest surface, and the cheapest one to copy. The Analysis tab owns **no data of its own**
beyond its watchlist: each of its three views is one call into the subsystem that already holds
the answer.

| View | Call | Lives in |
|---|---|---|
| My trades | `Atr_Ledger_ItemTotals()` | `AuctionatorLedger.lua` |
| Crafting | `Atr_Craft_ProfitRanking()` | `AuctionatorFinderProfession.lua` |
| Market | `Atr_An_Stats(name)` | its own file — the one thing it does own |

**The arithmetic lives with the data, not with the table that draws it.** That is what keeps the
crafting view and the trade skill window's own profit sort from disagreeing: both go through
`Atr_Craft_GetCraftCost` and the one reagent cascade above. A view that computed its own figures
would be a second opinion nobody asked for.

Two more globals belong to that tab and are worth knowing before adding anything that needs an
item ID from a name: `Atr_An_IdForName(name)` and `Atr_An_LearnId(name, id)`
(`AuctionatorAnalysis.lua`). The index behind them is assembled once per session out of tables the
addon already keeps for other reasons — **every reagent of every harvested recipe carries an `id`
and a `name`**, every ledger row carries both, and every observed watched item carries one — so
most lookups cost nothing and need no capture. Only what cannot be answered that way is learned
from a live link and saved (BACKLOG item 27).

### Localization

`ZT()` (`AuctionatorLocalize.lua:32`) is the upstream wrapper. The Finder cluster uses `FT()`,
a thin local wrapper published on `F`. Use `FT` in Finder-family files, `ZT` elsewhere.

---

## 7. The two grab-bags

**`Auctionator.lua` — 6,248 lines, 206 globals.** Upstream's core plus two local blocks. It
holds, in one file: event registration, the frame-art canvas, the SELL browser, the expanded
SELL layout, profit-margin filters, price recommendation, history parsing and condensing,
active-auction display, mass cancel/undercut, stacking preferences, dropdown builders,
autocomplete and time helpers. It is the file to *read from*, rarely the file to *add to*.

**`AuctionatorHints.lua` — 2,464 lines, and the only local file with no header comment.** Five
unrelated concerns: tooltip hint rendering, **the pricing API** (§6), disenchant value tables,
vendor price learning and prediction (which has its own research doc), and the AH scaled-variant
database. That the codebase's most-called pricing functions live in a file named "Hints" is the
clearest misfiling here.

Neither is a crisis. Both are worth knowing about before going looking for something.

---

## 8. Recipes

### Adding a main tab — 15 sites, all in `Auctionator.lua`

The Bazaar author tagged every one with `-- BAZAAR_TAB`, so the census is exact:

| Site | What |
|---|---|
| `:120`, `:121` | `local BAZAAR_TAB = 5` + `ATR_BAZAAR_TAB` global mirror |
| `:854` | `Atr_AddSellTab(ZT("Bazaar"), BAZAAR_TAB)` |
| `:859` | call the subsystem's `Init` |
| `:952`, `:972`, `:983` | `_AUCTIONATOR_*_TAB_INDEX` + the two `Atr_FindTabIndex` branches |
| `:1242`, `:1244` | hide own panel on tab change; own `OnTabClick` |
| `:1284`, `:1290` | set `gCurrentPane`; set the window title |
| `:1321`, `:1388` | exclusions in the tab-click path |
| `:5565`, `:5575` | add to `Atr_IsTabSelected` / `Atr_IsAuctionatorTab` |

Mechanical, but skip one and the symptom is remote from the cause. `grep -n BAZAAR_TAB
Auctionator.lua` is the checklist; **tag the new sites the same way.**

Two later tabs followed it exactly and are the worked examples to copy from: `-- LEDGER_TAB`
(item 7) and `-- ANALYSIS_TAB` (item 8, 15 sites). `grep -n ANALYSIS_TAB Auctionator.lua` is the
most recent census.

### Adding a view to an existing own-panel tab

The Analysis tab carries three views over one table and the panel, scroll frame and rows are
shared, because they are the expensive part. What differs per view is a **column table** and a
**row builder**, and adding a fourth would be:

1. A `AN_*COLS` table: one entry per column with `key` (unique across every view — each row
   Button carries every view's FontStrings and shows one set), `head`, a minimum width `w` and a
   `grow` weight, an optional `tip`, and `val` for the sort.
2. `An_LayoutCols(YOUR_COLS, AN_ROW_W)` in `Atr_An_Init`, plus a `headerSet` call and the cell
   loop — all three already iterate a list of column tables.
3. A `An_RedisplayYours()` and a branch in `Atr_An_Redisplay`.
4. A view button, and the view's name added to `Atr_An_SetView`'s Show/Hide walk.

Nothing is re-anchored on a switch: every row already holds every view's cells. That is the whole
trick, and it is why the switch is Show and Hide only.

### Adding a sub-tab (the Current / Ledger strip)

Cheaper: a `TabButtonTemplate` button in `Auctionator.xml` (~`:1004`), bump
`PanelTemplates_SetNumTabs` in the `OnLoad`, and add a branch to `Atr_ShowWhichRB`
(`Auctionator.lua:4488`) plus the matching `AtrPane:SetToShow*`. Note the `OnShow` handler
carries a comment forbidding tab selection there — read it before adding anything to that frame.

### Adding a subsystem file

The established pattern, best exemplified by `AuctionatorFinderPriceDB.lua`:

1. New file, `.toc` entry after `AuctionatorFinder.lua`.
2. Header comment naming the file's job, what it exports, and what it captures from `F`.
3. `local addonName, addonTable = ...` then `local F = addonTable and addonTable.Finder`.
4. Own event frame if it needs events (each subsystem owns its own; there is no central
   dispatcher outside `Atr_EventHandler`, and that is fine).
5. Own panel via `CreateFrame` if it needs UI (§4, World 2).
6. Guard on `rawget(_G, "CreateFrame")`-style checks where you want it loadable offline —
   several files do, and it is what makes the maths unit-testable.

### Adding a Finder option

Row in `AuctionatorFinderOptions.lua` (`:66` builds the checkbutton, `:118` loads, `:130`
saves), persisted into `AUCTIONATOR_FINDER_SETTINGS`. No `.toc` change — that variable is
already declared.

---

## 9. What is missing

**A mock-WoW test harness — for *this* addon.** Ten comments across four files say a function
is "global for the harness" or "so the mock-WoW harness can unit-test the maths without a real
window" (`AuctionatorFinderProfession.lua:343`, `:375`, `:396`, `:435`,
`AuctionatorFinder.lua:23`, `:82`, `AuctionatorFinderScanThrottle.lua:46`, and others).
**No such harness is in the repo for Auctionator.**

**But the repo is not without one — PassLootBiS has three, and they pass.** Run from the repo
root under bare `lua5.1`, no client:

```
management/addons/passlootbis/tools/contract-check.lua     20 assertions
management/addons/passlootbis/tools/usable-smoke.lua       14 assertions
management/addons/passlootbis/tools/report-smoke.lua       3 passes, exits non-zero on a crash
```

Plus in-game `*_SELFTEST` hooks in seven source files across both PassLoot addons. So the
pattern, the location convention (`management/addons/<addon>/tools/`, not shipped) and the
"stub the client, exercise the maths" technique are all established here already — an
Auctionator harness would be following a local precedent, not inventing one.

That makes the gap sharper rather than softer: this addon has already paid the design cost of
being testable — functions deliberately kept global, `addonTable` guarded so files load outside
the client, `CreateFrame` existence checks — and is the one addon that gets none of the
benefit. Every change here is currently verified by reading plus an in-game test.

**This is a note, not a proposal.** The owner's standing preference is to ship a reasoned change
and verify it in play, with tooling as a fallback rather than a frontline
(`management/docs/CLAUDE.md`, Environment) — so this gap is not something to close pre-emptively,
and a first run that fails is the accepted cost of moving quickly. It is recorded because when
something here *does* need pinning down — a fix that failed once, or arithmetic that genuinely
resists reasoning — both the hooks and the local precedent already exist, so the cheap route is
a few assertions under `management/addons/auctionator/tools/`, not a new in-game command.

---

## 10. Assessment: reorganize, or document?

**Document. Do not reorganize now.** Reasons, in order:

1. **The local code is already well-decomposed.** Eleven of the twelve local files have a clear
   single job and a header explaining it. The decomposition that has happened — pulling
   profession, merchant, throttle, price-DB and item-count out into their own files — went the
   right way and left honest notes about why.
2. **A refactor cannot be verified here.** No harness, no test suite, no way to run the client.
   Moving upstream code with reading as the only check is a poor trade.
3. **Moving upstream code costs the one diff we have.** With no upstream remote, the ability to
   recognise untouched upstream by indentation and comment density (§2) is a real navigational
   asset. Reformatting or relocating upstream blocks destroys it.
4. **The backlog barely touches the messy parts.** Seven of the nine items land in local files
   that are already clean. Only item 1 enters World 1, and only shallowly.

### The exceptions worth doing anyway

Small, verifiable by reading, and each pays for itself on a backlog item:

| Priority | Change | Why now |
|---|---|---|
| ~~1~~ | ~~Unify the reagent price cascade (§6) into one helper~~ | **Done 2026-08-19** — now `Atr_Craft_ReagentPrice`, collapsed while building backlog item 2. |
| 2 | **Give `AuctionatorHints.lua` a header comment** listing its five concerns | Ten minutes; it is the file people will land in looking for the pricing API. |
| 3 | **Extract SELL browser + layout** (`Auctionator.lua:1569–2721`) into `AuctionatorSell.lua` | 793 lines, 100% 4-space in a tab file, zero upstream interleaving — it is already a separate file. Shrinks the monolith by 13%. Do it as its own commit, moving code *without editing it*, before item 1 rather than during. |
| 4 | **Write the tab-adding recipe into a comment** at `Auctionator.lua:120` | The `-- BAZAAR_TAB` trail already encodes it; one comment makes it findable. |

Not recommended: splitting `AuctionatorHints.lua`, renaming globals, converting the codebase to
a namespace, or touching upstream files that no backlog item needs.

---

## 11. Where the backlog lands

**Snapshot, 2026-08-19, kept as the structural map rather than the status board.** Items 7 and 8
have both shipped since — the Ledger and then the Analysis tab, the latter growing a crafting view
(item 8's B2) and everything in items 24–27 on top. `BACKLOG.md`'s "Suggested order" is the live
view of what is left; what this table is still good for is the *world* column and the file map.

| # | Item | Files | World | Notes |
|---|---|---|---|---|
| 1 | SELL header icon → title hover | `Auctionator.lua:2335-2600`, `Auctionator.xml:768` | **1** | Only World 1 item. Easier after extraction #3 above. |
| 2 | Enchanting profit | `AuctionatorFinderProfession.lua` | — | Touches the duplicated cascade. |
| 3 | Multi-output yield | `AuctionatorFinderProfession.lua` | — | Diagnostic extends `/atrprofsort` (`:735`). Same cascade. |
| 4 | Stats dropdown learns keys — **DONE** | `AuctionatorFinder.lua` `Fdr_LearnStatKeys`, `Fdr_StatDD_Initialize` | 2 | Shipped: `statKeys` in the existing `AUCTIONATOR_FINDER_SETTINGS`, no `.toc` change. |
| 5 | `My Lvl` off by default | `AuctionatorFinder.lua:3558` | 2 | Smallest item in the list. |
| 6 | Recipe "already learned" filter | `AuctionatorFinder.lua` + `...Profession.lua:198` | 2 | Per-character cache — the exception to account-wide. |
| 7 | **Ledger** | **new file** + 15 tab sites, or a sub-tab | 2 | Own panel, own file, `F` surface. Rename existing tab to History (§8 sub-tab recipe). |
| 8 | Advisor | new file | 2 | Blocked on §5 — no market series exists. |
| 9 | Grovewood Log/Plank | investigation | — | Parked until 7 lands. |

Item 7 is the only one needing a genuinely new home, and the pattern for it is fully
established: `AuctionatorLedger.lua`, own panel in Lua, `F` surface, own event frame, tagged
`-- LEDGER_TAB` at every core touch-point.

**That prediction held, twice.** Item 7 shipped exactly that way, and item 8 followed it again as
`AuctionatorAnalysis.lua` — own panel, own file, tagged `-- ANALYSIS_TAB`, no upstream file
edited. Item 8's "blocked on §5" note was the one thing that did not hold, and §5 above says why:
it shipped by asking a different question rather than by waiting for the series.
