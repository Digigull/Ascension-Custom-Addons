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

---

## 4. Do Buy-tab searches update the price database and the tooltip? — ANSWERED: yes; the report was lying

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

## 8. NEW — a "Ledger" sub-tab beside Current and History, per item

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
