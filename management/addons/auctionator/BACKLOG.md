# Auctionator — request backlog

Owner's live request queue. Opened 2026-08-21. This file is the queue and the record of what each
item actually means against the code as it stands; it is not a design doc. When an item is built,
its findings go in a proper per-topic doc (the way `VENDOR-PRICE-RESEARCH.md` and
`HISTORY-STORE.md` did) and the entry here shrinks to a link.

Anchors are `file:line` at the time of writing and will drift; the symbol names next to them are
the durable part.

**Recorded 2026-08-21, seven items.** Items 1, 4 and 7 are features with real depth; 2, 3, 5 and 6
are layout and wiring. Item 4 is the only one that may be a bug rather than a request, and it is
written up as a diagnosis rather than a fix, because the write path it doubts turns out to exist.

**Built 2026-08-21: items 1, 2, 3, 5, 6 and 7**, in three branches; **item 6 reopened and finished
2026-08-22** after the first in-game session, which is written up under it. **Item 4 was answered 2026-08-22** and its premise was wrong:
the feed works, the report's clock was mislabelled. **Item 8 is new, 2026-08-22, nothing built.**

**Item 4 reopened and fixed 2026-08-20.** Only half of it had been answered. The write was never
the problem; the tooltip read the price by name while a Buy search files it under the item's
variant key, so a search could not move the tooltip of any item a full scan already knew. Written
up under the item. **Item 8 was built 2026-08-20** and its one open premise turned out to be
wrong in a way that changed the design: slot 3 is not free.

**Item 9 is new, 2026-08-20, and built the same day.** **Item 10 is new, 2026-08-20:** item 7's
"+Reagent List" menu entry had never once appeared in game, and the suite that covers that menu did
not load the file the entry depends on. Fixed the same day.

---

## 1. The History sub-tab shows the MARKET's price history, not your own postings — DONE

**Asked (owner, 2026-08-21):** *"I want the History tabs on the Buy, Sell, and My Auctions tabs to
use the new companion savedvariables history data (if not enabled in settings than have it say
enable the setting to see history), so the tabs will pull history for whatever item is selected and
show price history for it."*

**What the tab is today.** `Atr_ListTabs` (`Auctionator.xml:988`) is the *Current / History* strip
over the results list, shared by all three upstream tabs. Tab 2 calls `Atr_ShowWhichRB(2)`, which
routes through `Atr_UpdateUI` (`Auctionator.lua:4449`) to **`Atr_ShowHistory`**
(`Auctionator.lua:5222`). That renders `gCurrentPane.sortedHist`, built by
**`Atr_Process_Historydata`** (`:3642`) out of `AUCTIONATOR_PRICING_HISTORY[itemName]` — dated rows
of **your own postings**, each marked `yours = true`, with a `type` (posted / sold / expired).

So the tab is correctly named and answers the wrong question. It says *"here is what you did with
this item"*; the owner wants *"here is what this item has been worth"*.

**What would feed it.** `AuctionatorHistory.lua` already exports everything needed, and none of it
is called from this file yet:

| | |
|---|---|
| `Atr_Hist_Available()` `:201` | is the companion addon installed at all |
| `Atr_Hist_Enabled()` `:207` | is the setting on |
| `Atr_Hist_Series(name, now)` `:619` | the whole dated series, decoded |
| `Atr_Hist_Delta(name, days)` `:686` | week-over-week move |
| `Atr_Hist_Median(name)` `:766` | the honest median, age-weighted |

**THE THREE STATES ARE NOT TWO, and the request only names one of them.** The owner asked for
"enable the setting to see history", which covers *installed but off*. There are three:

1. **Companion missing** — `Atr_Hist_Available()` false. Telling someone to enable a setting they
   cannot reach is worse than saying nothing. This case must name the folder.
2. **Installed, switch off** — the owner's case. Say which setting, and where.
3. **On, but empty for this item** — the ordinary case for days after switching on, and the one
   most likely to read as broken. "Nothing recorded yet for this item; it fills in as you scan."

**Open decisions, and the first is the real one.** *Does the market series replace the posting
history on this tab, or sit beside it?* Replacing loses the only record of what you actually sold
things for — which is exactly what the Ledger tab was built to hold, so the loss may be acceptable.
Sitting beside it means either two sections in one list or a third sub-tab, and `Atr_ListTabs`'s
`PanelTemplates_SetNumTabs(Atr_ListTabs, 2)` (`Auctionator.xml:1014`) plus the deliberately-hidden
Tab3 make a third tab cheap to re-open. **Recommend: replace, and let the Ledger keep your own
trades** — but this is the owner's call and the build should not start until it is made.

Second: the rows carry `stackSize`, `when`, `yours` and `type`, and a market series has none of
those. Either the row shape gains a "market" kind that renders date + price only, or the series is
rendered into the existing columns with the ones it cannot fill left blank.

### Built 2026-08-21

**The owner's call: replace.** The History sub-tab shows the market series only; your own postings
are read on the Ledger, which holds the trades that actually happened rather than the ones you
asked for.

**"Replace" is true of the tab and false of the store, and that distinction is the whole of why
this was not a one-line change.** `Atr_Process_Historydata` looked like a display builder and is
not: its return value is your most recent posting price, which `AtrScan:ProcessBatch` feeds into
every scan as `__atrLast` (`AuctionatorScan.lua:580`), and `AuctionatorShop.lua:232` calls it too.
Repointing it at the market series would have changed all three silently. So the series went into a
**parallel list** — `gCurrentPane.marketHist`, beside the untouched `sortedHist` — and only the tab
moved.

**The tab was never a passive display, which is the second thing the request did not say.** Clicking
a history row sets `histIndex`, and `Atr_UpdateRecommendation` prices your auction from
`sortedHist[histIndex]`. Rendering one list while pricing from another would have made row 3 of what
you clicked price from row 3 of a list you cannot see — so the recommendation reads `marketHist`
too. The rows deliberately **do not** set `yours`, which is the field whose absence does something:
the recommendation undercuts anything not yours, and a daily close is the market's price, so
clicking one undercuts it exactly as clicking a Current row does.

**Three states, not the one the request named** — `Atr_Hist_PaneMessage`, tested in that order so
"off" cannot swallow "not installed":

| State | What it says |
|---|---|
| Companion folder missing | names the folder; `Atr_Hist_Enabled()` is false here too, so this must be tested first |
| Installed, switch off | names the setting **and** `/atrhistory on` |
| On, empty for this item | says the record fills in by scanning — the ordinary state for the first few days |

The message is raised in **`Atr_UpdateUI`, after its own `Atr_SetMessage ("")`**, not inside
`Atr_ShowHistory`: the clear runs after the draw, so a message set while drawing is wiped a line
later. It also has to be there because `Atr_UpdateRecommendation` is create-auction mode only —
without it, Buy and My Auctions would show a blank list rather than a reason.

**Two things found and fixed on the way.** A day number renders through `date()` in **local** time,
so the midnight that starts day N is the previous calendar day for anyone west of UTC and every row
would have been labelled a day early — the row's timestamp is **midday**. And the option's own
tooltip still said *"Nothing reads it yet"*, which this change makes false; it now names its
readers.

**Where it lives:** `Atr_Hist_PaneRows` / `Atr_Hist_PaneMessage` in `AuctionatorHistory.lua` (the
store shapes its own rows — `FRAMEWORK.md` §6), `Atr_Process_MarketHistory` and the render/price
sites in `Auctionator.lua`, one field in `AuctionatorPane.lua`.

**Verified:** `luac5.1 -p` clean; the four Auctionator suites still pass (114 + 31 + 27 + 25); and
the new reader was exercised offline against a seeded series — newest-first ordering, thin days and
folded weeks carried through, `yours` unset, midday timestamps, and all three message states
resolving in the right order. **Not verified in game:** the row text in the real list, the message
in `AuctionatorMessage2Frame`, and what clicking a row does to the sell recommendation.

**One consequence to watch in testing:** with the companion off, the History tab is now a sentence
instead of a list, and on the SELL tab that removes a pricing basis you could previously click. That
is the replace decision working as asked, not a bug — but it is the thing most likely to feel like
one.

---

## 2. The Ledger tab does not fill the window — DONE

**Asked (owner, 2026-08-21):** *"On the Ledger tab, let use the dimensions for spacing like the
Analysis tab has, it needs to shift to the right and fill out the window correctly."*

**Straightforwardly true, and the fix already exists one file over.** The Ledger hardcodes
Blizzard's 768px auction house:

```
AuctionatorLedger.lua:823   panel:SetSize (738, 447)
              :862   scroll:SetSize (690, ...)
              :871   rowsHolder:SetSize (700, ...)
              :877   line:SetSize (660, ...)
```

The Analysis tab hit this exact bug and fixed it by **measuring** (`AuctionatorAnalysis.lua:3536`):
`AuctionFrame:GetWidth()` minus 22, falling back to 768 when the window is not laid out yet, with
row and scroll widths derived from that and the scrollbar's lane taken off the panel rather than
off the rows. The comment there records what went wrong when the lane was reserved twice.

**The work is to port that arithmetic, not to invent one.** Both files should end up computing the
panel width the same way, and the Ledger's four hardcoded widths become derivations. Column x
offsets (`:845`, `:882`) are laid out from a table and will need the same treatment as
`An_LayoutCols`. Ascension's window is wider than 768, which is why the tab currently sits left
with a band of dead backdrop to its right.

### Built 2026-08-21

Ported, not reinvented: `Ldg_LayoutCols` and the measured panel in
`Atr_Ledger_Init` are `AuctionatorAnalysis.lua`'s `An_LayoutCols` / `Atr_An_Init` with the two lanes
this table does not have (the delete button, the plan tick) taken out. **Both tabs now answer "how
wide is the auction house" the same way**, which is the point — two answers is how one of them ends
up wrong again.

**Five hardcoded widths became one measurement.** `frameW` from `AuctionFrame:GetWidth()`, panel =
that minus 22, rows = panel minus the heading inset, the scrollbar's lane and 4. The scrollbar lane
comes off the **panel**, never off the rows — a `FauxScrollFrame`'s bar hangs outside the scroll
frame, so reserving it in both places spends it twice and leaves the table short of the right edge
by that much again. That is the mistake the Analysis comment records and it is not repeated here.

**Columns are a table now** (`LDG_COLS`, with the same `w` / `grow` / `just` fields the Analysis
columns carry), and headings compute their x from the same entry the cells do — they used to be five
hand-counted numbers kept in step with five more a hundred lines below. **Item is the only column
that grows**, and deliberately: a date is a date, a quantity is two characters and money is money,
so widening any of them buys nothing; the item name is the one cell that gets truncated and the one
this server makes long.

**Verified** by running the real `Ldg_LayoutCols` over four window widths offline: at 768, 1024 and
1200 the last column ends exactly on the row's right edge with nothing left over, and a
not-laid-out-yet `GetWidth` falls back to 768. Row field names are unchanged, so
`Atr_Ledger_Redisplay` needed no edit at all. **Not verified in game.**

### Also 2026-08-22 — a filter box, where the Analysis tab keeps its own

**Asked (owner):** *"On the ledger tab can you add a filter box, top left area (same position as
Analysis tab)."*

`Atr_Ledger_FilterBox` at the Analysis box's exact coordinates — label `(72, -40)`, box `(76, -52)`,
90x20 — which transfer without adjustment because the two panels are laid out identically. The x of
72 rather than the 24 that looks like the left margin is inherited rather than rediscovered: at 24
both the label and the box run under the auction house's character portrait, which is drawn over
them, and the Analysis tab's comment records that.

Matching on item name, lowercased plain `find` like `An_PassesFilter`, filtering as you type. A row
with only a link is matched on the name inside the brackets — filtering the raw link would match on
colour codes and item ids.

**The trap, and it was worth the separate function.** The filter is `Ldg_VisibleRows()`, deliberately
NOT folded into `Ldg_Rows()`: the Clear button's confirmation counts rows with `#Ldg_Rows()`, and
Clear deletes the whole ledger regardless of what is filtered. A filtered `Ldg_Rows` would have made
the popup ask *"Delete all 3 ledger rows?"* while deleting 412.

**The totals follow the filter and say so.** Money summed over the rows on screen is the number a
filter is typed to ask for — "what did I spend on Saronite" — but "412 rows, out 900g" printed under
three visible rows reads as the whole ledger's, so the count names both: **"3 of 412 rows"**.

---

## 3. The Ledger's Clear button: confirm it, and move it under the X — DONE

**Asked (owner, 2026-08-21):** *"I also want the Clear button to have a confirmation and be placed
on the upper section (right side corner) under the X button."*

**Today:** `Atr_Ledger_ClearButton` (`AuctionatorLedger.lua:911`) is 70x22 at the panel's
BOTTOMRIGHT, and its `OnClick` calls `Atr_Ledger_Clear()` **immediately** (`:916`). One misclick
destroys the trade ledger, which is the one store in this addon that **cannot be re-derived by
scanning** — every other database regrows, this one is a record of things that happened.

**So the confirmation is the important half of this item, not the placement.** `StaticPopupDialogs`
is the right mechanism (`ATR_AN_NEW_SLIST` in `AuctionatorAnalysis.lua` is the local precedent for
registering one). The popup should say **how many rows** are about to go — a count makes the
consequence concrete in a way "Are you sure?" does not.

**Placement:** top-right, under `AuctionFrameCloseButton`. Worth checking against the money frame
(`AuctionFrameMoneyFrame`, shown on Buy) and the tab's title, which is centred at `:833`.

### Built 2026-08-21

**The confirmation was the half that mattered, and the reason is worth keeping.** Every other store
in this addon regrows: prices and the mean set come back by scanning, vendor learning by visiting,
the recipe book by opening a profession window, the market history by scanning again in its own
file. **The ledger does not.** It is a record of things that happened, and nothing in the client can
be asked for them a second time — so it was the one destructive button in the addon with no question
attached.

`StaticPopupDialogs["ATR_LEDGER_CLEAR"]`, with `showAlert` for the yellow (!), and **the row count is
in the question**: "Are you sure?" is a noise people click through, "Delete all 412 ledger rows?" is
a consequence. The second line says scanning cannot bring it back, which is the fact that makes this
button different from every other one here. If the popup machinery is somehow absent the click falls
through to the old immediate behaviour rather than doing nothing.

**Moved to the panel's TOPRIGHT, under the close button**, at (-16, -46) — clear of Blizzard's 32px
close button above it and stopping short of the dark backdrop, which starts at -70. It came off the
BOTTOMRIGHT, which on the Analysis tab is where a tab-level *action* button lives (Rescan); Clear is
not that kind of button, and up in the chrome is where a destructive control belongs. It also gained
a tooltip saying what it deletes and that it will ask first.

**Verified:** `luac5.1 -p` clean, the four Auctionator suites still pass. **Not verified in game** —
the popup's wording at width, and whether (-16, -46) sits where the owner means by "under the X".

### Moved off the tab entirely, 2026-08-22

**Asked (owner):** *"Let's remove clear button from ledger, it could be confused for clear the
filter box. Put it into options interface instead."*

**The placement above was wrong for a reason the placement above created.** (-16, -46) is the tab's
top chrome row — and the filter box that landed on the Ledger tab the same day (item 2) sits on that
same row, a few inches to its left, at (76, -52). A 70px button reading **"Clear"** next to a text
input is read as *clear the input*. The confirmation does not save it: a player who clicks Clear
meaning "empty the filter box" and gets **"Delete all 412 ledger rows?"** has been frightened by a
control that was never for them, and the next such popup is one they have already learned to dismiss.

**So it left the tab rather than moving around on it.** There is no spot on that panel far enough
from the filter box to fix the reading, and a *record* is not a thing you clear in passing anyway:
it is a maintenance action, and Interface > AddOns > Auctionator > **Scanning** is where you go
looking for one.

- The tab keeps nothing but a comment where the button was — the superseded placement and *why* it
  is superseded, since (-16, -46) was itself a deliberate decision and the next reader will
  otherwise re-make it.
- **The button is still built by `AuctionatorLedger.lua`** (`Atr_Ledger_BuildOptionsButton`), which
  is handed a panel and a y offset by `Fdr_Options_Ensure`. The ledger owns what clearing means —
  the row count, the popup, the warning; the options file owns *where things sit on that panel*.
  That split is the point: two files choosing absolute offsets on one shared panel is how rows end
  up drawn on top of each other, and `AuctionatorFinderOptions.lua` now says in its header that it
  owns everything below y -110 there.
- The popup, the row count in the question and the tooltip moved **unchanged**. Item 3's reasoning
  survives the move intact; only its coordinates did not.
- Its own **"Trade ledger"** heading at -252, the button at -276, and a visible note under it at
  -304 saying what is deleted and that nothing brings it back — on the panel, not only in the
  tooltip, because a consequence nobody hovers to read has not been given.
- **An empty ledger asks nothing.** `#Ldg_Rows() == 0` says so in chat and skips the popup:
  "Delete all 0 ledger rows?" is a question with no consequence behind it, and answering Yes to one
  teaches the habit of answering Yes to the one that has.

**Verified:** `luac5.1 -p` clean on both files; the five Auctionator suites still pass (27 / 68 /
114 / 25 / 20). **Not verified in game** — that the four y offsets clear each other on the Scanning
panel at its real height, and that the note's 560px wrap does not run past the panel's edge.

---

## 4. Do Buy-tab searches update the price database and the tooltip? — the write: yes. The tooltip: NO, fixed 2026-08-20

**Asked (owner, 2026-08-21):** *"I don't think that Buy tab searches are updating the price data in
the database or tooltip, it should."*

**Recorded as a diagnosis, because the write path exists.** `AtrSearch:Finish`
(`AuctionatorScan.lua:764-790`) loops every scanned item and writes `gAtr_ScanDB` — that is
`AUCTIONATOR_PRICE_DATABASE[realm_Faction]`, the table the tooltip reads. It is the shared engine
for **all three** upstream tabs, so a Buy search reaches it. Two gates sit on the write and neither
is obviously the culprit:

- `Atr_CalcNewDBprice` (`:1243`) returns 0 when the scan found no buyout at all — correct, and it
  would mean the search returned nothing to price.
- `(scn.itemQuality or 0) + 1 >= AUCTIONATOR_SCAN_MINLEVEL` (`:779`) — but that variable defaults
  to **1, "poor (all) items"** (`Auctionator.lua:793`), so by default it excludes nothing. Worth
  confirming on the owner's install: it is settable from the options panel
  (`AuctionatorConfig.lua:828`), and the *full scan* path additionally **deletes**
  `gAtr_ScanDB[name]` for anything below it (`AuctionatorScan.lua:1475`).

**THE LEADING SUSPECT IS THE VARIANT KEY, and it is specific.** Line `:784` stores through
`Atr_PriceStore (gAtr_ScanDB, scn.itemName, newprice, vkey)` where `vkey` comes from
`Atr_VariantKey (scn.itemLink)`. A targeted search **has** a link, so it files the price in that
variant's slot; a tooltip or a name-only reader asking for the plain name may be reading the name's
default, which that write never touched. This is the same seam the archive's item 12 part 3 opened
deliberately, and a Buy search is exactly the path that always has a link.

**So the first move is not a fix.** It is to establish which of three things is happening — the
search never reaches `Finish`, the price is written where the reader is not looking, or it is
written correctly and the *tooltip* is the stale half. **`/atrprices`** — bare, with no argument — is that instrument
(`Fdr_PriceDB_Report`, `AuctionatorFinderPriceDB.lua:231`). A before/after on one item name answers
it in one search. Only then is there a change to write.

**The command is `/atrprices` and it takes no verb for this** (recorded 2026-08-22, after the name
`/atrpricedb status` was given to the owner from memory and turned out not to exist). The parser
treats any word that is not `on`, `off` or `reset` as an **item name** and routes it to
`Fdr_PriceDB_Inspect`, so `/atrprices status` looks up an item called "status" rather than printing
the report. The four forms that exist:

| Form | What it does |
|---|---|
| `/atrprices` | the report: feed ON/OFF, name counts for both databases, last write, quality floor |
| `/atrprices <item>` | inspect one item — what is stored for it and why |
| `/atrprices on` \| `off` | toggle the feed, then print the report |
| `/atrprices reset <item>` \| `reset all` | recalibrate the median |

**The reading to take:** `/atrprices` before a Buy-tab search, then search one item, then
`/atrprices` again — if *last write* does not move, the feed is not firing on that path at all,
which is a different bug from a stale tooltip. `/atrprices <that item>` afterwards settles whether
the write landed under a key the reader is not looking at.

**It prints to chat**, which this repo's own rule says a diagnostic should not do — but it is six
short lines rather than forty numbers, so a screenshot carries it. If the answer turns out to need
paging through more than that, it wants a copy box first.

### Answered 2026-08-22, from the owner's two readings

```
Finder price feed: ON
  price DB: 5977 names, mean DB: 5977 names
  last write: 126 minutes ago
  quality floor: 2

Price DB inspect: Moss Agate
  auction (gAtr_ScanDB): 1g 70s
  median samples (gAtr_MeanDB): 4/15
    86s 50c, 86s 50c, 1g 04s, 3g 94s
  tooltip shows -> auction 1g 70s   median 95s 25c
```

**Buy-tab searches DO write the price database, and always did.** The write is
`AuctionatorScan.lua:775-811`, in `AtrSearch`'s finish path: `Atr_PriceStore (gAtr_ScanDB,
scn.itemName, newprice, vkey)`, then a mean sample, then the dated history sample. Every Buy and
Sell search runs it. The item's premise was wrong.

**What was actually broken is the instrument, and it is why the impression formed.** The report's
`last write` line read `AUCTIONATOR_LAST_SCAN_TIME` — set **only** when a full scan finishes
(`AuctionatorScan.lua:1566`) or by the Finder's own feed (`AuctionatorFinderPriceDB.lua:209`). The
per-item path never touches it, and **must not**: that timestamp gates the 15-minute full-scan
cooldown, so writing it on every Buy search would reset the cooldown each time. So "last write: 126
minutes ago" after an evening of searching was reporting the last *full scan* under a label that
reads as *the database*.

**Fixed by splitting the one clock in two**: `last full scan` keeps the saved timestamp, and `last
search wrote` reads a new session-only global `gAtr_LastPriceWrite`, set in the per-item write path.
Session-only on purpose — the question is "are my searches feeding it *now*", so an unwritten one
says "not yet this session" rather than "never".

**The other two numbers are both healthy, for the record.** `5977 names` in each database is the
expected shape, not a coincidence: the same block appends a mean sample whenever it stores a price,
which the comment at `:790` says was fixed for exactly this reason. And Moss Agate's auction price
(1g 70s) legitimately differs from all four of its median samples — they are different statistics
off the same listings, `Atr_CalcNewDBprice` against `Atr_ScanListingsMedian`: one the low-price
estimate, the other the quantity-weighted median of the whole book.

**What is left of this item is the tooltip half, and it is now cheap to test.** `/atrprices` before
and after a Buy search: `last search wrote` moving to 0 proves the write. If a tooltip is still
stale after that, the fault is in the read path rather than the feed — a different bug with a
different fix, and worth its own item rather than living on under this one.

### Reopened 2026-08-20 — the tooltip half was real, and it was the read

**Owner, after a full update:** *"went to buy tab, searched item, closed AH, price not updated on
tooltip."* The paragraph above called this correctly and then the item was closed anyway, because
the write had been proved and the write was never the question.

**The cause is the seam this item's own "LEADING SUSPECT" paragraph named and nobody followed.**
`AtrSearch:Finish` files a targeted search's price under the listing's variant key —
`Atr_PriceStore (gAtr_ScanDB, name, price, vkey)`, and a Buy search *always* has a link, so it
always has a key. `ShowTipWithPricing` (`AuctionatorHints.lua`) asked `Atr_GetAuctionPrice
(itemName)` **by name alone**, and a name-only lookup answers `dflt`, which `Atr_PriceStore` sets
to the `ATR_PV_ANY` slot whenever that slot exists. `ATR_PV_ANY` is written by the full scan, the
Finder feed and the Bazaar — and by nothing else. So the number the search had just written sat one
slot away from the number the tooltip read, indefinitely, until the next full scan.

Both halves are correct in isolation, which is why reading either one kept exonerating it: the
store's preference for `ATR_PV_ANY` is deliberate and load-bearing (a stale cheap variant must not
pin a name below market — the `Large Fang` case recorded at `Atr_PriceStore`), and a name-only
reader getting the name's default is the documented contract. What was missing is that the tooltip
is not a name-only reader. **It has the link in its hand and never used it.**

**The asymmetry that hid it, and the reason a quick test kept passing.** On an item the database has
never seen there is no `ATR_PV_ANY` slot, so `dflt` falls through to the variant and the tooltip is
correct. The bug appears *only* on an item already known — i.e. on essentially everything, for
anyone with a full scan behind them, and on nothing in a fresh check. Confirmed against the real
store rather than reasoned: a row left as `{ ["?"] = 17000, ["1206:0"] = 9500 }` answers 17000 by
name and 9500 by key.

**Fixed on the read side, at the four sites that hold a link:** the tooltip's Auction line and its
craft-profit line (`AuctionatorHints.lua`), and the Sell browser's `Atr_SB_BestMethod` and Crafted
Goods Margin filter (`Auctionator.lua`), all now pass `Atr_VariantKey (link)`. The write path is
untouched — it was right. This cannot lose a price: `Atr_PriceValue` falls back to the name's
default whenever the variant slot is empty, which is every row written before variants existed.

**The remaining name-only readers are name-only by construction** and are left alone: the DE
essence lookups, the profession tabs (a recipe knows a name, not a link), `Atr_GetAuctionBuyout`'s
string branch, and `/atrprices` itself.

**`/atrprices <item>` was lying too, in the same way**, and that is how this survived the first
investigation: it printed one name-only number as *"tooltip shows -> auction ..."*. It now lists
every variant slot for the row and labels the name-only figure as name-only, so the divergence that
caused this is visible in the instrument that is supposed to find it.

**Pinned:** `management/addons/auctionator/tools/price-variant-smoke.lua`, 20 assertions — the
stale-vs-fresh pair, the unseen-item case that made the bug invisible, the legacy bare-number rows,
and the `Large Fang` invariant the store exists to protect. Written because this escaped a whole
investigation, which is the case the house rule reserves a new test for.

**Verified:** `luac5.1 -p` clean on the three edited files; the four existing Auctionator suites
still pass (27 + 31 + 114 + 25) and the new one passes. **Not verified in game** — the read path is
reasoned plus pinned offline.

**One thing worth deciding:** the quality floor is 2, applied as `itemQuality + 1 >= floor`, so
**grey (quality 0) items are never priced**. Almost certainly wanted; recorded because it is the one
silent exclusion in this path and would otherwise look like the same bug next time somebody looks up
a grey item.

---

## 5. Bazaar: "Price these" becomes "Rescan", bottom-right — DONE

**Asked (owner, 2026-08-21):** *"On the Bazaar tab I want to change the text of the button 'Price
these' to 'Rescan' move the button to the bottom right corner and make it about the same size and
position of the existing 'Rescan' button that is found on the Analysis-Market page."*

**Today:** `Atr_Bz_ScanButton` (`AuctionatorBazaar.lua:1669`), text `BZT("Price these")`, width
`BZ_BTN_W = 130` (`:433`), anchored **BOTTOM-centre** of `AuctionFrame` (`:1354`).

**The target it must match** is `Atr_An_RefreshButton` (`AuctionatorAnalysis.lua:4011`): **76x22, at
the panel's BOTTOMRIGHT, offset (-22, 30)**.

**Two things the rename must not break.** The button is a **toggle** — `:3482` swaps its text to
`BZT("Cancel")` while a scan runs, so the new label needs the same treatment and "Rescan/Cancel" is
the pair (which is exactly what the Analysis button does at `:3400`). And `:1028` disables it on the
ITEM view (`gBz_View ~= "ITEM"`), so the moved button must still land somewhere sensible on that
view rather than under the item detail. The comment at `:428` explains why it was put on the bottom
bar in the first place — returning from an item left the cursor over it and a second click
re-scanned — so **the move should keep it away from wherever the Back button leaves the cursor**,
and that comment needs updating in the same edit rather than left arguing for the old position.

### Built 2026-08-21

*(Recorded 2026-08-22: this section was written when the code shipped and lost before the file was
saved — the commit went out, the record did not. Reconstructed here.)*

`BZ_BTN_W/H` are **76x22** and the button is anchored `("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22,
30)` — the same numbers as `Atr_An_RefreshButton`, not numbers that look like them.

**The Bazaar panel had to learn its real width first, and that is the part worth knowing.** It was
`SetSize (738, 447)` — Blizzard's 768px window minus insets — and *nothing inside the Bazaar had
ever noticed*, because its table pane anchors its own BOTTOMRIGHT to `AuctionFrame` directly and so
already filled the wider Ascension window. The moment a button anchors to the **panel's** right
edge, that stale width stops being invisible: -22 from a 738-wide panel is a button floating in the
middle of the backdrop. So the panel now measures `AuctionFrame:GetWidth()` the same way the
Analysis tab and the Ledger do. Three tabs, one arithmetic.

**The oversized font came off.** It was `GameFontNormalLarge`, which suited a 130px button on the
bottom bar and clips "Rescan" at 76px.

**Both of the named hazards are handled.** The toggle still swaps to `BZT("Cancel")` while a scan
runs, and the cursor-over-the-button trap is gone by construction: Back is on the filter row, Rescan
is now in the opposite corner, so returning from an item cannot leave the pointer on it. The `:428`
comment that argued for the bottom bar is rewritten rather than left standing, and the per-frame
reposition that measured the button onto the bottom bar off `Atr_Buy1_Button` is deleted — an anchor
to the panel's corner does not move.

**Verified:** `luac5.1 -p` clean, the four Auctionator suites pass. **Not verified in game.**

### Also 2026-08-22 — the category summary line came off

**Asked (owner):** *"removed the text on the bazaar tab under the drop down 'x tradeable of y...'
that whole line of text."*

`Atr_Bz_CatSummary` and the block that filled it are gone. It took with it the only caller of
**both** `Atr_Bz_CategoryCounts` and `Atr_Bz_PricedCount`; they are left in place — global, cheap,
each answering a question the tab may want asked again — with a comment saying they are now
unreferenced, which is worth knowing before editing either expecting something to depend on it.

---

## 6. "Full Scan..." and "Options" into the top-right corner — DONE

**Asked (owner, 2026-08-21):** *"The Buy, Sell, and My Auctions tabs each have two small buttons in
the upper right section, 'Full Scan...' and 'Options', I want to squeeze those buttons in the upper
right section of each tab also."*

**Today:** both are XML, in the shared World 1 panel — `Auctionator1Button` ("Options", 70x18,
`Auctionator.xml:460`) and `Atr_FullScanButton` ("Full Scan...", 74x18, `:473`). Options is
anchored **LEFT of `Atr_Search_Button` + 165px**, and Full Scan hangs off Options' left edge. So
their position is derived from the Buy tab's search button — which is *hidden* on Sell and My
Auctions — and that is why they sit mid-panel rather than in a corner.

**Note the label is already overridden at runtime:** `AuctionatorFinderFullScan.lua:494` retexts it
to **"Scan Categories..."**, because upstream's getAll full scan is dead on this server. The item
should say which label is meant; the visible one is "Scan Categories...", which is 4 characters
longer and drives the width.

**The work** is to re-anchor both to the panel's top-right rather than to a Buy-only widget. These
are World 1 widgets shared across three tabs (`FRAMEWORK.md` §4), so the change must be *reversible
per tab* or apply to all three identically — the SELL tab's expanded layout already saves and
restores widget geometry (`Atr_Sell_SaveGeom`), and anything moved into that region has to be
checked against it. Also check `AuctionFrameCloseButton` and the money frame for collisions, and
item 3 puts the Ledger's Clear button in the same corner on a different tab.

### Built 2026-08-21

`Atr_Sell_PlaceTopRightButtons` (`Auctionator.lua`), called from `Atr_Init` once the panel exists.
Options sits at `("TOPRIGHT", AuctionFrame, "TOPRIGHT", -28, -46)` and Full Scan keeps its anchor to
Options' left edge, so the pair travels together.

**Three decisions, and the first is the one that would have gone wrong silently.**

**It is placed in Lua, not in the XML.** The buttons anchor to `AuctionFrame`, which **does not
exist when `Auctionator.xml` is parsed** — it arrives with `Blizzard_AuctionUI`, which is what calls
`Atr_Init` in the first place. An XML anchor naming it would resolve against nothing. The XML
anchors stay in place, with a comment saying they are overwritten, so the buttons are never
unanchored in between.

**Anchored to the window, not to the panel**, for the same reason item 5 had to measure the Bazaar:
the shared panel carries Blizzard's 768px width and Ascension's window is wider, so the panel's
right edge is not the window's.

**`ATR_SELL_GEOM` was checked and neither button is in it**, which is the concern this item raised:
the SELL tab's expanded layout neither saves nor restores them, so it cannot undo the placement, and
one placement genuinely serves all three tabs — they are the same widget objects (`FRAMEWORK.md`
§4).

`(-28, -46)` is item 3's line for the Ledger's Clear button, so the two land on the same rule: clear
of Blizzard's 32px close button above, short of the headings bar below.

**Verified:** `luac5.1 -p` and `ET.parse` clean, the four Auctionator suites still pass. **Not
verified in game** — whether `(-28, -46)` clears the money frame on the Buy tab is the thing to look
at first.

### Reopened and finished 2026-08-22 — "each tab" meant ALL of them

**Owner, in game:** *"Are the options and full scan small buttons supposed to be in yet? Because I
only see them on the original 3 tabs still."*

**The request was read too narrowly and the build above is half the item.** "Squeeze those buttons
in the upper right section of each tab **also**" means all eight Auctionator tabs; what shipped
moved them within the three they were already on. The owner's own diagnosis was right: *"something
about the old tabs and new not functioning the same with ui elements"* — `Atr_AuctionFrameTab_OnClick`
calls `Atr_Main_Panel:Hide()` and shows a World 2 panel in its place, and both buttons are children
of that shared panel, so they leave with it. Nothing was wrong with the placement; they were inside
the thing that gets hidden.

**Reparented to `AuctionFrame`, and shown by tab.** `Atr_Sell_SyncTopRightButtons(index)` shows them
when `Atr_IsAuctionatorTab(index)` and hides them otherwise — every path that changes tab, including
`Atr_SelectPane` and the hooked original, runs through that one function, so opening the window, a
tab click and the saved default tab are all covered. Without the hide they would appear over
Blizzard's own Browse / Bid / Auctions.

**The frame level is load-bearing.** The World 2 panels are also `AuctionFrame`'s children and are
created *after* this pair, so at equal level they draw over the buttons and eat the clicks. That is
the old queue's item 22 — the Buy tab's buttons dead for three rounds over exactly this — and +20 is
the margin that fixed them.

**They moved up one line, because the line item 6 chose is already taken on four of the five newer
tabs**: the Ledger's Clear `(-16, -46)`, the Advisor's Ignored `(-20, -46)`, the Analysis view strip
`(-26, -50)` and the Finder's Search `(-18, -49)`. One shared pair cannot own a line four tabs
already use, so it sits at `(-40, -20)` — between the close button and that row, level with the
centred title, which is empty out to the right edge on every tab.

**A separate bug, found while moving them, and the owner's own wording is the evidence.**
`AuctionatorFinderFullScan.lua`'s relabel to "Scan Categories..." was a bare `if` at **file scope**,
and at file scope `Atr_FullScanButton` does not exist — the button is created with `Atr_Main_Panel`
inside `Atr_Init`, which does not run until `Blizzard_AuctionUI` loads, long after that file is
parsed. The guard was always false, so the button has read "Full Scan..." all along, which is what
the owner called it when asking for this item. It is now `Fdr_FS_RelabelButton()`, called once the
button exists. **The claim in the Built section above that the visible label is "Scan Categories..."
was wrong.**

### And the label went back, 2026-08-22

**Asked (owner), after seeing it for the first time:** change "Scan Categories..." back to **"Full
Scan..."** on all tabs.

The retitle is retired — no relabel runs, so the button keeps the label its XML gives it. Which is
the label it has always shown in practice: the retitle was a bare `if` at file scope where
`Atr_FullScanButton` does not exist yet, so it never fired until 2026-08-22, when fixing it changed
the button's name for the first time. It now reads "Full Scan..." on purpose rather than by
accident.

The reasoning behind the old name is kept in `AuctionatorFinderFullScan.lua` as superseded rather
than deleted: *"Full Scan..." is a misnomer once gear is excluded and the scan is category-driven*
is still true of what the button **does**, and the next person to read that file will have the same
idea.

**Not renamed:** `Atr_FullScanStartButton`, the button **inside** the full-scan frame, still says
"Scan Categories" / "Cancel". It is a different widget on a popup rather than on a tab, and the
request named the one with the ellipsis.

**Known rough edge, not fixed:** `Atr_UpdateUI_SellPane` disables both buttons while a Sell search is
processing and re-enables when it finishes. Switch tabs mid-scan and they stay greyed on every tab
until it completes. Transient and self-correcting, so it is recorded rather than worked around.

**Verified:** `luac5.1 -p` and `ET.parse` clean, the four suites pass. **Not verified in game.**

---

## 7. Analysis right-click: "Add reagents list" — DONE

**Asked (owner, 2026-08-21):** *"On the analysis tab, if you right click a craftable item, i want to
have a new context option under Shopping with blue text that says 'Add reagents list' so that you
can make a new shopping list with the name of that item as the name of the shopping list and the
reagents will be added automatically."*

**Everything this needs already exists.** It is an assembly, not a build:

| Piece | Where |
|---|---|
| The menu, as a pure function returning `{ text, func, disabled, header }` | `Atr_An_MenuEntries` (`AuctionatorAnalysis.lua:2949`) |
| Its "Shopping list" section, with `New list...` already in it | same, `:2960-2981` |
| Per-row colour — the renderer already colours headers green and disabled rows grey | `Atr_An_ShowItemMenu` (`:3186`) |
| A recipe's reagents by item name | `Atr_Craft_*` — `AUCTIONATOR_CRAFT_RECIPES` stores `{ made, reagents = { {id, name, count}, ... } }` (`AuctionatorFinderProfession.lua:442`), and the name-keyed tooltip harvest returns `{ {name, count} }` (`:632-639`) |
| Creating a list and filling it | `Atr_SList.create(name)` and `Atr_SList:AddItem(itemName)` (`AuctionatorShop.lua:29`, `:63`) |

**Four decisions the request leaves open, and each changes the code:**

1. **Blue is a new row kind.** The renderer colours by `header` and `disabled` only; this needs a
   third case (an explicit `color` field is cleaner than a fourth boolean). `|cff40a0ff` reads as
   blue against the menu's dark backdrop without competing with the green headers.
2. **The entry must not appear for a non-craftable item.** The menu is built from a name alone, so
   the test is "does a recipe exist that makes this" — `Atr_Craft_HasRecipe(link, name)` (`:604`) is
   that test and is name-tolerant. **An entry that is present but does nothing is worse than an
   absent one**, so it should be omitted rather than shown disabled.
3. **A name collision has to do something predictable.** Adding the reagents for the same item
   twice should not silently make a second list of the same name. Reusing the existing list and
   topping it up is the behaviour that matches what the button says.
4. **A reagent the recipe knows only by ID.** The ID-keyed store carries names too (`:437`), but a
   shopping list is name-keyed — anything that cannot be resolved to a name must be reported rather
   than dropped, or the list quietly under-buys.

**One thing worth deciding at the same time:** whether the list gets the *reagents* only, or the
reagents the plan says you are **short of** — the Reagents view already computes Need vs Have. The
request says reagents, and reagents is the smaller, more predictable thing; note it here so the
question is not rediscovered later.

### Built 2026-08-21

**A blue "Add reagents list" under Shopping**, and one new reader in the file that owns the recipes.

**`Atr_Craft_ReagentList(link, name)`** (`AuctionatorFinderProfession.lua`) returns
`{ {name, count}, ... }`, the yield, and a count of what it had to drop. It lives there rather than
beside the menu for `FRAMEWORK.md` §6's reason: **the two harvests write two different record
shapes** into `AUCTIONATOR_CRAFT_RECIPES` — the window harvest keys by the made item's ID with
reagents carrying both an id and a name, the tooltip harvest keys by NAME with names only — and a
caller reading that table itself would work against one and silently return nothing for the other.
It resolves ID first then name, the same order `Atr_Craft_HasRecipe` uses, so the menu entry can
never be offered for a recipe the action then cannot read.

**On the four open decisions:**

1. **No new row kind was needed.** The colour is embedded in the entry's own text
   (`|cff40a0ff...|r`), which a FontString renders directly — so the renderer is untouched and no
   fourth boolean joins `header`/`disabled`. The blue earns itself: every other entry in that
   section files ONE item onto a list, and this one creates a list and fills it with several OTHER
   items.
2. **Omitted, not disabled**, exactly as the item argued — the entry is only built when
   `Atr_Craft_ReagentList` actually returns something.
3. **A second click tops up the existing list** and says so ("Topped up X: 2 added, 1 already on
   it") rather than making a second list of the same name. Nothing is ever removed.
4. **A reagent with no resolvable name is dropped and counted**, never left as an ID — a shopping
   list is searched by name, so an ID entry is a row that can never match anything.

**The trap that offline testing caught:** `Atr_SList.create` **sorts** the list table it inserts
into, so the index a new list ends up at is not the end of the array. The action re-reads
`Atr_Shop_UserLists()` after creating rather than assuming — without that, the reagents file into
whichever list happened to sort into that slot.

**Quantities are lost, and it is the shopping list's shape rather than a shortcut**: `Atr_SList`
holds names, with nowhere to put "x12". The Reagents view is where counts live and it prices them;
this is the shopping trip. On the question the item flagged for deciding early — reagents, or only
what you are short of — this ships **reagents**, as asked.

**Verified** offline: the existing `analysis-feed-smoke` harness plus 8 throwaway assertions over
the new path — the entry appears for a craftable item and not otherwise, it is blue, the list is
named after the item, it holds the three reagents rather than the item, and a second click neither
duplicates the list nor doubles its contents (39 passed). The four shipped suites still pass and
`luac5.1 -p` is clean. **Not verified in game.**

---

## 8. A "Ledger" sub-tab beside Current and History, per item — DONE

**Asked (owner, 2026-08-22):** *"add new tab next to 'Current' and 'History' called Ledger on the
original 3 tabs, to reference any ledger data about the item."*

**The name is free because it was given up for exactly this.** `Atr_ListTabs`
(`Auctionator.xml:988`) held *Current* and *Ledger* until the Ledger main tab was built, and tab 2
was renamed to **History** then — it showed the scanned item's price history and was the odd one
out. `AuctionatorLedger.lua`'s own header records the swap: *"the label was the odd one out.
Renamed to History, which frees the name for the thing that is actually a ledger."* This item
reclaims it for that thing.

**Tab 3 already exists and is hidden, not deleted** (`Auctionator.xml:1002`). The XML comment there
says why: `Atr_UpdateUI` still has an `else` branch calling `PanelTemplates_SetTab(Atr_ListTabs, 3)`
and `Atr_ShowWhichRB(3)` must still resolve, so the frame was left in place. So the third tab is a
`hidden="true"` to remove and a `PanelTemplates_SetNumTabs(Atr_ListTabs, 2)` (`:1014`) to make 3 —
**but it is currently wired to `Atr_ShowHints`**, the dead hint system whose sources (Wowecon,
GoingPrice, `gAtr_ScanDB`) are not installed. Reusing slot 3 means deciding whether the hints
branch goes or moves; leaving it and adding a fourth is the alternative.

**What it would show.** `AUCTIONATOR_LEDGER.rows` filtered to this item — the same records the
Ledger main tab draws, narrowed to `gCurrentPane.activeScan.itemName`. Every piece exists:
`Atr_Ledger_DB()`, the `LDG_SRC` kind/colour table, and `Atr_Ledger_ItemTotals()`, which the Advisor
already calls for realised margin per item. **The reader should be one function in
`AuctionatorLedger.lua`**, the way item 1 put `Atr_Hist_PaneRows` in `AuctionatorHistory.lua`: the
pane should not learn the ledger's row shape.

**Three things to settle before building:**

1. **Rows, or a summary, or both?** The ledger for one item is often two or three rows, and the
   number worth reading is the one `Atr_Ledger_ItemTotals` already computes — bought N at X, sold M
   at Y, realised Z. A list of three rows under four columns built for a market history may read as
   emptier than a sentence would.
2. **The tab strip is driven by `IsScanEmpty`** (`Auctionator.lua`, `Atr_UpdateUI`) — it hides
   whenever there is no scan. Ledger data exists for items you are *not* currently scanning, but
   this strip is per-scanned-item by construction, so the tab inherits that and should not fight it.
3. **The empty state matters more here than on the other two**, because it is the common one: most
   items you look up have never been traded. It should say "you have not bought or sold this"
   rather than draw nothing — the same lesson item 1 recorded about three states.

**Related, already shipped:** item 1 made the History sub-tab read the market series and left your
own postings unread there; this is where the "what did *I* do with this item" question goes.

### Built 2026-08-20

**The tab is id 4, not 3, because slot 3 was not free — this item's own premise was wrong.**
The note above (and the XML comment it was drawn from) called the hint view dead, "whose sources
(Wowecon, GoingPrice, `gAtr_ScanDB`) are not installed". Two of those three are indeed absent, and
the third is the point: `Atr_BuildHints` reads `gAtr_ScanDB` *and* `Atr_GetMostRecentSale`, both of
which exist on this install. Worse, the branch is not reachable "only through this button" as the
XML claimed — `Atr_OnSearchComplete` calls `SetToShowHints()` directly when a **create-auction**
search comes back with no current listings. So the hint view really does appear, on the Sell tab,
at precisely the moment you have nothing to price against, and taking its slot would have replaced
a pricing hint with a trade record exactly when the hint is worth having. A fourth id costs
nothing: `PanelTemplates` only indexes the tabs it is told about, and a hidden one in the middle is
invisible to it. The stale XML comment has been corrected in place rather than left to mislead the
next reader.

**On the three things this item said to settle:**

1. **Rows *and* a summary, not one or the other.** The summary goes in the **column heading**
   (`Atr_Col3_Heading`), not into a row: an item you have traded is two or three rows, and the
   number the tab is opened for — *bought 20 for 3g40s | sold 20 for 4g84s | realised +1g44s* —
   would scroll away from the thing it summarises if it were a row. Bought and sold only. Postings
   and deposits are on the rows and are deliberately not in the sentence: an auction still up has
   not resolved, and a margin quoted over it would be inventing a result. The margin line only
   appears once both sides exist.
2. **The strip's `IsScanEmpty` behaviour is inherited, not fought**, as the item said.
3. **The empty state is the common case and says so** — "You have not bought or sold this", with a
   different line when the whole ledger is empty, since those are different answers. Delivered the
   way item 1 did it: `Atr_Ledger_PaneMessage` through `Atr_SetMessage`, in the block that already
   runs after the draw.

**What is where.** The reader is three functions in `AuctionatorLedger.lua` — `Atr_Ledger_PaneRows`
(one item's rows, newest first), `Atr_Ledger_PaneSummary`, `Atr_Ledger_PaneMessage` — plus
`Atr_Ledger_ItemRecord`, which pulls one name out of `Atr_Ledger_ItemTotals` so there is exactly
one definition of "realised margin" and the Advisor's is it. The renderer, `Atr_ShowItemLedger`, is
in `Auctionator.lua` beside `Atr_ShowHistory`, because the strip is World 1 chrome. The pane never
sees a `src` tag or a copper field.

**Three decisions inside it that are not obvious:**

- **The money column is the UNIT price, not the total.** Current lists per-item buyouts and History
  lists per-item daily closes; the same column meaning the same thing across all three is what
  makes "I sold at 2g42, the market was at 2g40 that week" one tab-click to check. The total is in
  the row text where the quantity makes it differ.
- **A row that moved no money shows no money.** An expiry costs and earns nothing, and a money
  frame cannot render that — a zero in a price column reads as "sold for nothing". The frame is
  hidden and the gray text beside it carries a dash.
- **A ledger row is not a selection.** Clicking one used to fall through to the `else` that files
  the index under `hintsIndex` and then calls `Atr_UpdateRecommendation` — which would have priced
  your auction off whichever past purchase you happened to click. `Atr_EntryOnClick` now returns
  early on this tab.

**The cache is keyed by item and by a new `gAtr_LedgerRev`, not by "is it nil".** Nil-checking is
what the History tab does, and it is only safe there because every path that changes the item
happens to clear `marketHist`. This view has two more ways to go stale — picking a different item
out of a multi-item search summary swaps `activeScan` with no search starting, and the ledger
*grows while the auction house is open*, which is the whole point of buying something and then
looking. `Atr_Ledger_Add` and `Atr_Ledger_Clear` bump the revision; the pane compares it.

**One latent bug fixed in passing:** `Atr_Col1_Heading` had exactly one writer
(`Atr_ShowCurrentAuctions`, "Item Price") and the other tabs just `Show()`ed whatever it had left
there. Harmless while every tab meant the same thing by that column, and not harmless now the
Ledger labels it "Your price" — one visit would have renamed it everywhere. Both tabs now set it.

**Verified:** `luac5.1 -p` clean, `ET.parse` clean on `Auctionator.xml`, the five Auctionator
suites still pass (27 + 31 + 114 + 25 + 20). The reader was run against a synthetic ledger (buy /
post / sale / expire across two items) and its rows, summary, both empty states and the revision
counter check out; that caught the summary separator rendering as an empty string
(`|cff555555|r` with nothing between the codes). **Not verified in game** — the tab strip itself is
reasoned.

---

## 9. No way to delete an Analysis watch group — DONE

**Asked (owner, 2026-08-20, after testing item 8):** *"I just noticed though, i don't have a way to
delete watch groups on the analysis tab, maybe we can add some small red x buttons into the drop
down with confirmation?"*

**True: groups were create-only.** `Atr_An_AddGroup` (`AuctionatorAnalysis.lua:168`) appends and
sorts, `Add Group` calls it through a popup, and nothing anywhere removed one. A group typed with a
typo was permanent.

**The one real decision: what happens to the items in a deleted group.** A group is a *label*, and
deleting a label must not delete what it labels. Every item filed under the group stays watched and
loses its group. This is not a soft call — a watched item carries observation history in `db.obs`
that scanning rebuilt over days, and taking a dozen of them out with one click on a red x is
recoverable by no amount of rescanning. The confirmation names the count for the same reason, so
"delete" never quietly means more than it looks: *"Delete the group "Ore"? 14 watched items are
filed under it. They stay watched and lose the label; nothing else about them changes."*

**Why the Blizzard dropdown's list had to be replaced rather than added to.** `UIDropDownMenu` has
no per-entry widget in 3.3.5: its rows are the interface-wide globals
`DropDownList1Button1..N`, recycled by every dropdown in the UI, so an x parented to one of them
would turn up on somebody else's menu. This file had already met that class of problem — the note
above `Atr_An_MenuEntries` records two attempts at a Blizzard dropdown for the Buy tab and *"it
opened nothing either time"* — and already carried the answer: a plain frame it owns outright.

So **the dropdown box stays exactly as it is** — its art, its width, its text, `An_GroupDD_Init`
still installed — and only the list it opens is ours. One `SetScript` on `Atr_An_GroupDDButton`.

**What was added:**

- `Atr_An_DeleteGroup (name)` and `Atr_An_GroupCount (name)` beside `Atr_An_AddGroup` — pure data,
  no UI. Delete returns `nil` for "no such group" and a number for "removed, this many unfiled",
  because the caller has to be able to tell an empty group from a missing one.
- `Atr_An_GroupMenuEntries ()` — the pure menu shape, same bargain `Atr_An_MenuEntries` struck.
  "All groups" carries no x: it is not a group, it is the absence of a filter.
- `Atr_An_ShowMenu (anchor, title, entries, xoff)` — the item menu's show path, generalised so the
  group menu reuses the frame, the click-eater, the strata and the placement flip.
- An optional red x per row in `An_MenuRow`, a **child of the row** rather than a sibling: the row
  is a full-width Button, and two overlapping frames at the same level hand the click to whichever
  the layout engine puts on top. A child is unambiguously in front of its parent, so the x deletes
  and never selects.
- `StaticPopupDialogs["ATR_AN_DEL_GROUP"]`, with `showAlert`.

**One bug caught before it shipped, and it is the kind that confirms and then does nothing.**
`gAn_PendingGroup` — the group name that has to survive the menu closing — was first declared beside
`gAn_PendingItem`, which sits *below* `Atr_An_GroupMenuEntries`. The entries builder would have
assigned a **global** of that name while the popup, defined after the local, read the **local**: every
delete would have asked for confirmation and quietly done nothing. Declared above its only writer,
with a comment saying why it lives there.

**Pinned:** the existing `analysis-feed-smoke.lua` grew 22 assertions (31 → 53) — the counts, the
menu shape, deleting twice, an empty group versus a missing one, and the rule that matters: every
item in a deleted group is still watched and simply unlabelled, and other groups are untouched. Run
rather than reasoned because this is the only destructive operation on the tab's saved data.

**Verified:** `luac5.1 -p` clean; all five Auctionator suites pass (27 + 53 + 114 + 25 + 20).
**Not verified in game** — the frame work (the x hit area, the menu's placement under the dropdown)
is reasoned.

---

## 10. Item 7's "+Reagent List" entry never appeared — DONE

**Reported (owner, 2026-08-20, with a screenshot):** *"backlog 7 isn't working. Can you check this
out, I would like the text to be blue and underneath the Shopping List section '+Reagent List'"* —
the right-click menu on a Crafting-view row showed *Shopping list / Sample Shopping List #1 / New
list... / Analysis group / ...* and no blue entry at all.

**The cause is a key-type mismatch, and this file's own header warned about it.** The note above
`Atr_Craft_ReagentList` says the two harvests write two different shapes into
`AUCTIONATOR_CRAFT_RECIPES` and that *"a caller reading the table directly would work against one
and silently return nothing for the other"*. That function **was** that caller:

- the **profession window** harvest keys by the produced item's numeric ID (`db[madeID]`) — this is
  what fills the Crafting view's 891 recipes, i.e. essentially everything;
- the **recipe tooltip** harvest keys by name (`db[created]`) — far rarer;
- the Analysis menu had only a name and called `Atr_Craft_ReagentList (nil, itemName)`, so the
  lookup `AUCTIONATOR_CRAFT_RECIPES[name]` missed every window-harvested recipe.

The entry is gated on that same call returning something, so it was never built. Not "sometimes
broken": broken for every craft the owner could have tried.

**Fixed by resolving a name against the ID-keyed records**, in the file that owns the record shape.
`Atr_Craft_IdForName` builds a name → numeric-key map and memoises it, because the only way to match
a name to a numeric key is to ask the client what each key is called and doing ~900 `GetItemInfo`
calls per menu open is not a thing to do twice. It rebuilds when the record COUNT changes — counting
keys is a pairs loop over a table already in memory, naming them is the expensive half — so opening
another profession window refreshes it with nothing having to remember to invalidate anything.

The two Analysis callers now also pass `Atr_An_IdForName (itemName)` as the first argument. That is
not a second code path — a numeric first argument is the function's documented input — it just skips
the reverse index on the Crafting view, where the tab already knows the id.

**Also asked, also done:** the label is now **"+Reagent List"**. It was already blue
(`|cff40a0ff`) and already the last entry in the shopping-list section, above the *Analysis group*
header — the position in the request was already the intended one; it simply had never been seen.

**And the mark it shares with its neighbours** (owner, 2026-08-20, follow-up: *"change the plus
symbol to gold and add a plus symbol in front of New list and New Group"*). The `+` is gold
(`|cffffd100`) on all three, with only the reagents entry's *words* staying blue — so the menu now
reads `+New list...`, `+Reagent List`, `+New group...`, and the three "this makes something new"
verbs carry one mark instead of three near-misses.

Two details worth keeping. The `+` is **one constant**, `AN_PLUS`, not three copies of an escape
code — a fourth such entry should use it rather than a hand-typed colour. And it is **prepended
outside the `AZT()` lookup**, so the translation keys stay `"New list..."` and `"New group..."`: a
locale file carries the words and never the punctuation. That is also what lets the `+` keep its own
colour while the words keep theirs.

**Why the tests said nothing, which is the part worth keeping.** `analysis-feed-smoke.lua` covers
`Atr_An_MenuEntries` and passed 31 assertions while this was totally broken, because it loaded only
`AuctionatorAnalysis.lua` and `AuctionatorScan.lua`. The menu gate reads
`type (Atr_Craft_ReagentList) == "function"` — with the profession file unloaded that is false, so
the entry was skipped and the suite happily asserted the menu contents *without* it. A stub would
have reproduced exactly the same blind spot, since what was wrong was which key the real function
looks under. The suite now loads the real
`AuctionatorFinderProfession.lua`, and 11 new assertions build both harvest shapes and check that a
name alone finds each.

**Proved rather than assumed:** the new assertions were run against the pre-fix file, which returns
nothing for a window-harvested recipe asked by name, and against the fixed one, which returns its
reagents.

**Verified:** `luac5.1 -p` clean; all five Auctionator suites pass (27 + 68 + 114 + 25 + 20).
The colour segmentation was resolved back to plain text rather than eyeballed —
`[gold:+][blue:Reagent List]`, `[gold:+][default:New list...]`, `[gold:+][default:New group...]`.
**Not verified in game.**

---

## 11. The craft tooltip's yield mark was on the wrong line — DONE

**Asked (owner, 2026-08-20, with a screenshot of an Alchemy tooltip):** *"On the tooltip for
multicraft can you change Craft costx3 and remove the x3 there, then on Craft profit change it to
Craft profit(3)"*.

**They are right, and the old label was a claim about the wrong number.** A multi-output recipe is
shown PER CRAFT: `Atr_AddCraftProfitToTip` multiplies a per-item reagent cost back up by the yield,
so the figure beside *Craft cost* is the recipe's whole reagent bill for **one press of Create** —
not three of anything. `x3` beside it named the arithmetic used to get there and read as a
multiplier on the result.

The profit line is where the count actually earns its place: that margin is the whole press, so it
depends on selling all three. `(3)` states the yield without pretending to be a multiplier.

```
before                          after
  Craft cost x3      33g          Craft cost         33g
  Craft profit x3    65g          Craft profit (3)   65g
```

**What did not change, deliberately:** the *stack* multiplier. Hold Shift over a stack of five and
every line on the tooltip is scaled by five and says `x5`, the Auction line included — that is a
different annotation, it applies to the whole tooltip, and the two can never co-occur anyway
(`perCraft` requires no stack scaling). The `Craft loss` line takes the new mark too, being the same
row in the negative.

**The header comment was arguing for the old shape and is updated in the same edit** — marked
superseded rather than deleted, because "tag both lines, they are both scaled" is a reading somebody
will arrive at again.

**Verified** by driving the real `Atr_AddCraftProfitToTip` with a stubbed tooltip and printing the
lines it emits, across all five cases — the reported one, stack-scaled, a recipe that makes one, an
unknown market price, and a loss:

```
makes 3, hovering one (the reported case):
  Craft cost           33g
  Craft profit (3)     63g
makes 3, hovering a stack of 5 with Shift (stack scaling wins, no yield mark):
  Craft cost x5        55g
  Craft profit x5      105g
makes ONE (no mark at all):
  Craft cost           11g
  Craft profit         21g
makes 3, market price unknown:
  Craft cost           33g
  Craft profit (3)     unknown
makes 3, sells at a LOSS:
  Craft cost           33g
  Craft loss (3)       -30g
```

`luac5.1 -p` clean; all five Auctionator suites still pass (27 + 68 + 114 + 25 + 20).
**Not verified in game.**

---

## 12. Batch Post: the right half of the SELL inventory, and soulbound at the bottom — DONE

**Asked (owner, 2026-08-22):** *"On the Auctionator sell tab, divide the inventory area in half and
make the new (right half) called batch post, add items from inventory section into batch by right
clicking them. Press Batch Post button, sells at automatic set price discount, and whatever duration
is currently set. Also let's keep all soulbound items at the bottom, they are mixed in here and
there."*

**Built 2026-08-22.** New file `AuctionatorBatchPost.lua` (queue, panel, post driver); the SELL
tab's expanded layout splits the band and calls into it twice. Full write-up:
`management/addons/auctionator/BATCH-POST.md`.

Two findings worth carrying forward without opening that doc:

- **The soulbound half was a bug, not a preference.** Those items were already being *filtered out*
  — `Atr_IsItemSellableOnAH` cached its whole verdict under the **item link**, and boundness is not
  a property of the link, so whichever copy of an item was read first became the verdict for all of
  them. Bag order decided which. That is what "mixed in here and there" looked like from outside.
  The bind scan is per bag slot and uncached now; only the quality half keeps a link key. With the
  detection fixed they would have vanished entirely, which is not what was asked for, so they are
  kept in a `Soulbound` bucket above `Ignore` with their tiles inert.
- **The batch cannot price the way the sell box does, and says so.** The sell box queries per item
  and refuses to undercut listings that are *yours*; a batch cannot afford a query per item, so it
  prices off `Atr_GetAuctionPrice`'s cascade, which carries no owner. Consequence, documented rather
  than hidden: batch-posting the same item twice without a scan in between undercuts your own
  listing by one step. `Scan Inventory` is the fix and sits under the left column.

`luac5.1 -p` clean; XML parses; all nine offline suites still pass. **Not verified in game** — the
four things worth looking at first are listed at the end of `BATCH-POST.md`.
