# Auctionator — request backlog

Owner's live request queue. Opened 2026-08-21. This file is the queue and the record of what each
item actually means against the code as it stands; it is not a design doc. When an item is built,
its findings go in a proper per-topic doc (the way `VENDOR-PRICE-RESEARCH.md` and
`HISTORY-STORE.md` did) and the entry here shrinks to a link.

Anchors are `file:line` at the time of writing and will drift; the symbol names next to them are
the durable part.

**Recorded 2026-08-21, seven items, nothing built yet.** Items 1, 4 and 7 are features with real
depth; 2, 3, 5 and 6 are layout and wiring. Item 4 is the only one that may be a bug rather than a
request, and it is written up as a diagnosis rather than a fix, because the write path it doubts
turns out to exist.

---

## 1. The History sub-tab should show the MARKET's price history, not your own postings

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

---

## 2. The Ledger tab does not fill the window

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

---

## 3. The Ledger's Clear button: confirm it, and move it under the X

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

---

## 4. Do Buy-tab searches update the price database and the tooltip?

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
written correctly and the *tooltip* is the stale half. `/atrpricedb` (`AuctionatorFinderPriceDB.lua:240`)
already reports the table's state and is the cheapest instrument; a before/after on one item name
answers it in one search. Only then is there a change to write.

---

## 5. Bazaar: "Price these" becomes "Rescan", bottom-right

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

---

## 6. "Full Scan..." and "Options" into the top-right corner

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

---

## 7. Analysis right-click: "Add reagents list"

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
