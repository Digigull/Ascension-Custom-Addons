# Weapons and Armor in the Full Scan, and a level range per category

Owner's question, 2026-08-22: *"With the Auctionator addon, are we at a point that we can add
Weapon and Armor to the Full scan categories? If we are maybe we add a level range to each
checkbox (blank = all)."*

**Yes — as of the work written up here, and the answer had been yes for a little while without
anybody noticing.** The thing that kept gear out was never the scanning; it was that there was
nowhere honest to put a gear price. There has been somewhere since the scale-variant store was
built, and the one wire that was missing between the two is short.

Files: `Auctionator-Finder-Ascension/AuctionatorFinderFullScan.lua` (the picker and the queue),
`AuctionatorFinder.lua` (the scan engine, the harvest and the recording pass), `Auctionator.xml`
(the dialog got wider). Read `FRAMEWORK.md` first if you have not; this assumes the Finder's
scan engine and the two price databases.

---

## 1. Why gear was excluded, and what changed

The old rule, still in the file as superseded reasoning: **`gAtr_ScanDB` is keyed by item NAME.**
On Ascension one name covers many scaled instances at different item levels, so a single stored
price stands in for every version and is wrong for all but one. `Fdr_PriceDB_Update` **rule 2**
refuses scaled equipment for exactly that reason, so a gear sweep spent forty pages of scanning
to store almost nothing. The Weapon and Armor rows were therefore shown greyed and refused in
`Fdr_FS_IsSelected` as well, so a hand-edited SavedVariables could not smuggle them in.

All of that is still true **of the name-keyed database**, and rule 2 is untouched by this change.

What changed is that a gear price no longer has to be stored by name. Two things were built after
that decision was taken, each for its own reason, and together they are the whole answer:

| | |
|---|---|
| `AUCTIONATOR_AH_VARIANT` (`AuctionatorHints.lua`) | keyed `itemID:ilvl:req` — the tuple that names a scale-variant exactly. Written by `Atr_AHVariant_Note`, read back by the bag tooltip. Until now it was fed **only** by the Verify button. |
| `FdrBuy_HarvestTrueData` (`AuctionatorFinder.lua`) | reads a listing's **server tooltip**, which is the only place its real item level exists. Until now it ran only on a listing the buy engine had live-loaded. |

So the store existed and the reader existed; nothing filed gear into it in bulk. That is the wire
this adds.

## 2. The harvest: `Fdr_HarvestListIlvl`, and why it must happen during the scan

`GameTooltip:SetAuctionItem("list", index)` only answers for a listing on the **current page**.
That single sentence explains both the Verify button and this change:

* After a scan the pages are gone, so Verify re-finds each name with a fresh exact-name query and
  reads the tooltips off *that* result page. It is thorough and it is slow — one full query per
  distinct name.
* **During** a scan there is nothing to re-find. `Fdr_HarvestPage` is reading a page that is up
  right now, so the tooltip is one call away, and the cost is zero extra server traffic.

`Fdr_HarvestListIlvl (index, rec)` is that call, and it is **deliberately lighter than the Verify
read**:

| | Verify (`FdrBuy_HarvestTrueData`) | Scan (`Fdr_HarvestListIlvl`) |
|---|---|---|
| keeps | up to 40 rendered lines, with colours, plus true stats | `trueIlvl` and `trueDPS` |
| reads | every line | the first 15 — both numbers live in the header block |
| sets `fdrVerified` | yes | **no** |
| cost | one query per name | one tooltip per equippable listing |

It does not set `fdrVerified` because it has not earned it: the row's stat columns are still the
cached base item's. What it does earn is that the row stops being greyed (it knows its real item
level), its tooltip gets the correct `Atr_Finder_TipOverride`, and — the point — its price becomes
storable.

It runs **only when the spec asks for it** (`spec.harvestTrue`), which only the Full Scan's Weapon
and Armor categories set. An ordinary Finder search costs exactly what it did before, and a Trade
Goods page pays nothing for a feature with no equippable rows to use it on.

## 3. `Fdr_RecordScaleVariants`: what gets filed, and what refuses to be

One pass, called from two places that know very different amounts:

* **`Fdr_AnalyzeResults`** — the ordinary end of a scan, where every row has been enriched and
  `rec.scaled` decided.
* **`Atr_Finder_CancelSearch`** — where *nothing* has been, because a cancel never reaches the
  analysis pass. A gear sweep is the longest scan there is and cancelling one part-way is the
  ordinary case; binning the pages whose tooltips were already read would throw away precisely the
  most expensive work. So the pass re-derives what it needs (`IsEquippableItem`, and the base item
  level from a cached `GetItemInfo`) rather than requiring it.

Rules it keeps:

* **One session per call**, opened lazily and only if there is something to file.
  `Atr_AHVariant_Note` rule 1 is "cheapest listing wins inside a session, a new session replaces";
  one category sweep is exactly the *one snapshot of the market* that rule is written around.
* **A capped scan is refused**, for the reason `Fdr_PriceDB_Update` rule 3 refuses one: the
  cheapest listing of a variant may be on a page that was never reached, so every price would be
  biased high — and high is the direction that costs somebody a sale.
* **Counted per variant, not per write.** Several listings of one variant is the normal case and
  each cheaper one writes again, so a write tally would report the shape of the price list rather
  than what was learned.

**A cancelled sweep still replaces**, and that is a deliberate asymmetry with the name feed, which
goes insert-only on a partial (`Fdr_PriceDB_Update (nil, true)`). The variant store has no
insert-only mode, and its whole philosophy is that a fresh reading beats a stale one — a partial
sweep's price is a real listing price for that exact variant, seen just now; only its *lowest-ness*
is uncertain. Worth revisiting if it ever misprices something in practice.

## 4. Scaled detection got sharper for free

`Fdr_AnalyzeResults` decided `rec.scaled` from two signals: listings sharing a link but disagreeing
on required level, or a required level that disagrees with the base item's. A **lone** listing of a
scaled item whose required level happens to match its base one was invisible to both — and would
have had its price written into the name-keyed database as though it were an ordinary item.

A harvested row carries the server's own item level, so there is now a third test:
`trueIlvl ~= rec.ilvl`. It is the sharpest of the three and it only costs what the harvest already
paid for.

## 5. The level range

`AUCTIONATOR_FINDER_SETTINGS.fullScanLevels[tostring(ci)] = { min = n, max = n }`

* **Blank is the default and stores nothing** — an empty pair deletes its row rather than writing
  two zeroes, so the settings file stays the size of what you actually chose.
* **Stored under the CHECKBOX's class index**, and applied to every class that checkbox scans. The
  merged Miscellaneous row therefore ranges Projectile and Quiver too: one visible control, one
  meaning.
* **`Fdr_FS_Levels` returns a backwards range the right way round.** The server answers 80–70 with
  nothing at all, which reads in game as "the scan is broken" and is a miserable thing to debug
  from a status line.
* **The boxes write on every keystroke**, not on focus loss: pressing *Start Scanning* is a click
  elsewhere, and a box that commits `OnEditFocusLost` has a real chance of being read one keystroke
  stale by the very button the user pressed next. Each box writes the **pair** (it reads its
  partner), because the store keeps a range, not two independent numbers.
* `Fdr_SendQuery` reads `spec.minLevel` / `spec.maxLevel` and falls back to the Finder tab's own
  boxes, so nothing about an ordinary search changed — `Fdr_BuildSpecQueue` never sets those
  fields.

**It filters on REQUIRED level, which is the whole reason it belongs on gear rather than being a
convenience.** The required level is the one per-instance truth the list API reports for a scaled
item (ASCENSION-CLIENT-NOTES), so it is the very axis the scale-variants of one item differ along.
`Armor 70-80` is both a short scan and a real slice of the market; `Armor, everything` is neither.

## 6. What the run says it did

The two counters on the dialog are the *name-keyed* database, which refuses scaled gear by design —
so a gear run would otherwise report `0 new, 0 updated` having filed several thousand prices, and
the status line would add the actively discouraging `prices not saved - all N rows are scaled gear`.

Both now carry `%d gear prices by version` (per scan on the Finder's status line, per run on the
Full Scan dialog, including on a cancel), and the "all rows were scaled" note is suppressed when
the variant store took them. The number is distinct variants learned, not listings seen.

## 7. Layout

The picker gained a min/max pair on every row, which does not fit in the 405 points the old
`Atr_FullScanHTML` blob occupied. `Atr_FullScanFrame` is **520x455**, was 460x420; the picker panel
is 465 wide with columns 232 apart and the boxes at a fixed x within each column, so they line up
down the column however long the labels are. Nothing clips a child frame in 3.3.5, so the old
overflow would have been invisible in code and obvious in game.

The picker is still **built once** and reused (`gFS_Built`) — see `SELL-TAB-COST.md` on why a window
that rebuilds its widgets is a window that leaks them. `Fdr_FS_SyncPicker` puts the widgets back in
step with the store on each show, which matters only when something outside the file writes the
settings, but a picker showing a range it will not scan is the worst kind of wrong.

## 8. What this does not do

* **Stats stay the base item's.** The harvest keeps item level and DPS only. Verify is still the way
  to get a listing's full server tooltip, and the Verify button still appears for rows that want it.
* **`trueDPS` and the item-level pattern are enUS**, exactly as in the Verify read they were lifted
  from. Same limitation, no worse.
* **The variant store caps at 3000 entries** (`ATR_AHV_CAP`) and prunes to half when it overflows.
  A whole-class Armor sweep can push past that on its own, and the prune keeps the newest — which is
  the right half to keep, but it means a huge sweep can evict what a previous one learned. A level
  range is the answer, and if it stops being enough the cap is the number to revisit.
* **Nothing is verified in game.** All of it is reasoned and parses; the harvest cost per page in
  particular is an estimate.
