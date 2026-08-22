# Batch Post — the SELL tab's right-hand column

Built 2026-08-22 (BACKLOG item 12); **live price scanning and the progress bar added 2026-08-23
(item 13)**. Everything here is read from source or reasoned from it; the client cannot be run
here, so **nothing below is verified in game.**

The original request, verbatim: *"On the Auctionator sell tab, divide the inventory area in half and
make the new (right half) called batch post, add items from inventory section into batch by right
clicking them. Press Batch Post button, sells at automatic set price discount, and whatever
duration is currently set. Also let's keep all soulbound items at the bottom, they are mixed in
here and there."*

The follow-up, after the first in-game session: *"Let's have it scan the current prices at the batch
post time. Maybe have a progress bar, prices can change quickly."*

Three things, then, and the third — the soulbound half — turned out to be a bug rather than a
preference. They are written up in that order.

---

## 1. Where the code is

| | |
|---|---|
| `Auctionator-Finder-Ascension/AuctionatorBatchPost.lua` | **new.** The queue, the panel, the post driver. Loads last in the `.toc`. |
| `Auctionator.lua`, `Atr_ApplySellExpandedLayout` §3 | splits the band; calls `Atr_BP_Layout` |
| `Auctionator.lua`, `Atr_ResetSellExpandedLayout` | calls `Atr_BP_Unplace` |
| `Auctionator.lua`, `Atr_SB_Item_OnClick` | right-click queues / unqueues |
| `Auctionator.lua`, `Atr_SB_Build` | soulbound bucket, green wash on queued tiles, tail-calls `Atr_BP_Build` |
| `Auctionator.lua`, `Atr_Sell_ItemIsGrey` / `Atr_Sell_ItemIsBound` / `Atr_Sell_ItemDefIsBound` / `Atr_Sell_TextIsBinding` | the bound classification (§4) |
| `Auctionator.lua`, `Atr_Sell_BindDump` | `/atrbound`, the tooltip diagnostic (§4c) |
| `AuctionatorFinder.lua`, `Atr_Finder_CancelSearch` | calls `Atr_BP_ScanCancelled` (§3) |
| `management/addons/auctionator/tools/batch-price-smoke.lua` | **new.** 25 assertions over the two pricing functions |
| `management/addons/auctionator/tools/bound-scan-smoke.lua` | **new.** 48 assertions over the bind marker list and both tooltip sources |

**No new saved variable.** The queue is session-only on purpose — see §3.

The batch file takes `addonTable.Finder` at load (`local addonName, addonTable = ...`), the same
idiom the four Finder files use. That is what lets it read `F.GetResults()` and `F.GetState()`
directly, and it works because it loads **last** in the `.toc`, after `AuctionatorFinder.lua`
publishes that surface (FRAMEWORK.md §3, ordering fact 1).

FRAMEWORK.md §4's rule is "build new UI in World 2", and this is as close to that as a SELL-tab
feature can get: the panel, its rows, its buttons and the driver are all in one new file and all
built in Lua. What it cannot escape is that it shares a row with `Atr_SellBrowser`, which is
World 1, so the coupling is exactly two calls — `Atr_BP_Layout` from the expanded layout's apply
path and `Atr_BP_Unplace` from its reset path. **`Atr_BP_Unplace` is not optional.** The panel,
the "Inventory" label and both buttons are children of `Atr_Main_Panel`; nothing else hides them
on the way to the Buy tab.

---

## 2. The layout arithmetic

The inventory band is unchanged as a band — panel x −26 out to 598, 194 tall, top at −82. Six
constants in `Auctionator.lua` now split it, and they are the only place the split is decided:

```
ATR_SELL_BROWSER_Y = -82     top edge of BOTH columns
ATR_SELL_BROWSER_H = 194     height of BOTH columns
ATR_SELL_INV_X = -26         inventory left   -> right edge 264
ATR_SELL_INV_W = 290
ATR_SELL_BP_X  = 298         batch left       -> right edge 574
ATR_SELL_BP_W  = 276
```

**The 34px gap between the two is not padding.** A `UIPanelScrollFrameTemplate` anchors its scroll
bar to its own TOPRIGHT at +6 with a width of 16, so the bar lives *outside* the width you set,
from +6 to +22. The inventory's bar occupies 270–286. Narrow the gap and the bar lands on the
batch list. The batch column's own bar reaches 596, which is where the single wide inventory used
to end, so the band's right edge is unmoved.

The batch panel is placed 16px **above** `ATR_SELL_BROWSER_Y` because it carries its own title
row; the list inside it lines up with the inventory to the pixel, and both bottom out at −276.

`Atr_SB_Build` computes its tile columns from `Atr_SellBrowser:GetWidth()`, so halving the width
re-flows the inventory with no further change: 18 tile columns became 8.

**The two buttons ride `Atr_HeadingsBar`, not the panel.** That is the same trick `Scan Inventory`
already uses and for the same reason — the headings-bar divider is drawn *over* anything sitting
at the inventory's bottom edge, so a button anchored there is buried. They sit on the divider at
`ATR_SELL_SCANBTN_Y` with the frame level raised by 5, offset to the batch column's left edge
(`x - 6`, because the headings bar starts at panel x 6). The list itself deliberately stays at the
default level, *under* the divider, which is what the inventory does.

Nothing here calls `SetToplevel` or `Raise` (`DRAG-FREEZE.md`).

---

## 3. What the button actually does

### The price — scanned live, per item, as the run reaches it

**Changed 2026-08-23 (BACKLOG item 13), and this is now the centre of the feature.** The first
build priced off the stored database. The owner's follow-up: *"let's have it scan the current
prices at the batch post time. Maybe have a progress bar, prices can change quickly."*

The run interleaves a scan with each post rather than scanning everything up front:

```
for each queued entry, in queue order:
    if this NAME has not been scanned yet this run:
        Atr_Finder_StartNameScan (name)          -- one auction query
        ... wait, then read F.GetResults() ...
        price EVERY queued entry of that name off those listings
    post it
```

**Interleaved, not two phases, and that is the request rather than a detail.** Both orders cost the
same wall clock. Interleaved, the gap between reading an item's price and listing at that price is
one 0.25 s tick; batched, the first item posts at a price read minutes earlier — which is exactly
the staleness the owner asked to remove.

**Scanning by NAME, pricing every entry of that name from the one result set.** A queue holding five
stacks of Saronite Ore costs one query, not five.

**What it takes out of the results** (`Atr_BP_LiveUnit`): the lowest **per-unit** buyout among
listings that carry this item's variant key and are **not yours**.

- *Per-unit*: `buyoutPrice / count`. A stack of ten at 1000 undercuts a single at 150.
- *Variant-keyed*: `Atr_VariantKey(rec.link)` against the queued link's. Same-name variants are
  genuinely different items on this server and must not price each other (BACKLOG items 12/15/16).
- ***Not yours*: `rec.owner` is on every scan record, and this is the thing the price database
  throws away.** Pricing off the database meant undercutting your own standing listing every time
  you ran a batch twice. That limitation is gone, and it is why the scan reads the raw records
  rather than waiting for `Fdr_PriceDB_Update` to land them. A listing whose `owner` has not
  arrived yet counts as somebody else's — that costs at most one undercut step, where the other
  choice would mean ignoring real competition and listing above the market.

Then the ordinary arithmetic, `Atr_UpdateRecommendation`'s line for line:

```
buyout per item  = Atr_CalcUndercutPrice (lowest live listing)
start  per item  = Atr_CalcStartPrice (buyout)          -- AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT
stack prices     = both of the above x the stack size actually in the sell slot
duration         = UIDropDownMenu_GetSelectedValue (Atr_Duration), read once at run start
```

**Three outcomes, and `Atr_BP_EffectiveUnit` is the single place they are decided:**

| the scan came back with | the item posts at |
|---|---|
| listings that are not yours | the lowest of them, **undercut** |
| nothing listed (or only your own) | `Atr_GetAuctionPrice`'s cascade, **not** undercut |
| could not be scanned at all | that same cascade, **undercut** — i.e. the old behaviour |

The middle row is the one worth stating. With no competing listing there is nothing to undercut,
and shaving a step off an uncontested price is pure loss. "Only your own listed" lands here too,
which means a re-run matches your existing price instead of walking it down.

The bottom row happens when the Finder is not loaded, the query channel is busy, or a scan times
out. It is always **said in chat**, never silent.

**An item with no price from any of those is never guessed at.** It stays in the queue, greyed,
with "no price" where its total would be, and the run skips it.

### The progress bar

A run is now minutes rather than seconds — one throttled query per distinct name — so a column that
just sat there would read as a hang. `Atr_BP_Progress` is a `StatusBar` that takes the title's row
for the length of a run, so it costs no layout: a run has nothing to say that the title was saying.

Each queue entry is one unit of work. An entry out for a scan fills up to **0.8** of its own unit as
the query runs, driven off the driver's own tick counter, capped short of the item's full slice so
it can never run ahead of what actually happened. Without that the bar would freeze at precisely
the moments the run is doing the most work. The label alternates between
`Scanning <item>  (n/total)` and `Posting  n/total`.

### The driver is a ticker, not an event chain

`StartAuction` is asynchronous, and the client's completion signal is not the same for a one-stack
post as for a multi-sell run — `Atr_OnAuctionMultiSellUpdate` only ever sees the latter, which is
why this driver leaves `gAtr_SellTriggeredByAuctionator` alone and does its own bookkeeping.

The one thing that is true either way is that **the item leaves the auction sell slot when the
auction goes up**. So: post one, then poll `GetAuctionSellItemInfo()` every 0.25 s until the slot
is empty, then take the next. Six seconds without the slot clearing counts as a failure and the
run moves on — it never re-issues `StartAuction` for the same item, because that is how you post it
twice.

Entries that never reach the server (unpriced, or a slot that refused to load) cost no round trip,
so the driver walks past those *within* one tick. Spending 0.25 s each on a queue of unpriced items
would look exactly like a hang.

The run stops by itself if the auction house closes or the tab changes. Nothing is queued
server-side, so stopping is free, and a second click on the button cancels — the same gesture
`Scan Inventory` uses. A cancel also kills the name scan that may be in flight.

**The scan can be cancelled from outside, and that had to be wired both ways.** The per-name
callback rides `gFdr_OnFinish`, which `Atr_Finder_CancelSearch` clears — so a batch waiting on a
scan would sit there until its own timeout. That path already tells the Sell tab's Scan Inventory
driver (`Atr_SB_ScanCancel`); it now tells this one too, through `Atr_BP_ScanCancelled`. The
reverse direction is safe by construction: `Atr_BP_Cancel` nils `gRun` *before* calling
`Atr_Finder_CancelSearch`, so the callback coming back the other way short-circuits instead of
recursing.

Behind both of those sits a 45-second per-scan timeout in the driver. It is a backstop against the
callback being dropped by some path that routes through neither hook, not a per-query budget — the
Finder has its own paging retries and runaway guard. On a timeout the run says so and falls through
to the stored price rather than hanging.

### Three guards worth keeping

1. **`ClickAuctionSellItemButton`, not `Atr_ClickAuctionSellItemButton`.** The wrapper raises
   `gAtr_ClickAuctionSell`, which sends `Atr_OnNewAuctionUpdate` into `gSellPane:DoSearch` — a full
   auction query per item, on the channel this run needs, for a price it is not going to use. The
   one thing the wrapper does that *is* still needed is the `AuctionFrameAuctions.duration == nil`
   guard, so the driver carries that itself.
2. **The name check before every `StartAuction`.** Bag slots move on their own. If the sell slot
   does not hold the item that was priced, the post is abandoned rather than listing some other
   item at this one's estimate. This is the check that must not be dropped.
3. **The stack count comes from the sell slot, not from the queue.** The queue's count is only as
   fresh as its last rebuild; `GetAuctionSellItemInfo`'s third return is authoritative.

### The queue is held as links, not as bag slots

A queue of `(bag, slot)` pairs is stale the moment anything moves — and a batch run empties slots
as it goes, so it invalidates its *own* queue. `Atr_BP_Resolve` runs before every post: it
re-points each entry at a slot that really holds its link (preferring one with the same stack size,
claiming slots so two entries cannot land on one) and drops entries whose item has gone.

**Session-only, deliberately.** A batch you did not post is a decision about right now, and a
`/reload` dropping it is the correct amount of memory — the same reasoning that keeps the Advisor's
`skip` state out of `AUCTIONATOR_ADVISOR` (FRAMEWORK.md §5). It also means no new saved variable
and no new file to corrupt.

Capped at 60 entries. That is already the better part of a minute standing at the auctioneer; past
that this stops being a convenience and starts being a macro nobody asked for.

### Bookkeeping

Because the multi-sell handlers skip a batch entirely, each successful post calls, under `pcall`:
`Atr_AddToScan`, `Atr_AddHistoricalPrice`, `Atr_Ledger_RecordPost` (with `Atr_Ledger_NotePostIntent`
called while the item is still in the slot, which is the only moment the deposit is knowable) and
`Atr_LogMsg`. A batch that half-records is still a batch that posted, which is why none of them may
throw.

---

## 4. The bound bucket

Two rounds. The first (2026-08-22) fixed a caching bug that made the browser's *existing* soulbound
filter unreliable. The second (2026-08-23) fixed what that filter was **looking for**, after the
owner reported bind-on-pickup and "Realmbound" items still reaching the selling categories.

### 4a. Round one: a verdict that flipped with bag order

The owner's second sentence — *"keep all soulbound items at the bottom, they are mixed in here and
there"* — describes a symptom of a real bug, not a missing preference. Soulbound items were already
being **filtered out** of the inventory browser. They appeared anyway, and irregularly.

### Why

`Atr_IsItemSellableOnAH` cached its whole verdict in one table keyed by **item link**:

```lua
local itemSellableCache = {};
...
if (itemSellableCache[link]) then return itemSellableCache[link]; end
```

Quality is a property of the item, so a link key is right for it. **Boundness is not.** An item
link carries no trace of whether the copy in front of you is bound — a BoE you have worn and one
still in its wrapper share a link to the character. So whichever copy was read *first* became the
verdict for every other one, and bag order decides which that is. A verdict that flips with bag
order is not a filter, and "mixed in here and there" is exactly what it looks like from the outside.

### The fix, in two parts

**`Atr_Sell_ItemIsGrey(link, quality)`** keeps a link-keyed cache, because that answer really is
per-item. It reads the grey colour prefix off the link first so a cold `GetItemInfo` cannot force a
wrong answer, and it **refuses to cache "not grey" when the quality is still unknown** — otherwise
a cold item cache freezes into the browser for the rest of the session.

**`Atr_Sell_ItemIsBound(bag, slot)`** does the tooltip scan per **bag slot**, uncached. Nothing is
lost by dropping the cache: every caller walks each slot exactly once per build, so the cache never
had a second read to serve — it only ever served the wrong slot.

`Atr_IsItemSellableOnAH` is now the cheap test then the expensive one — grey first, bind scan only
if it survives — and it returns **two** values: sellable, and whether the refusal was boundness.
One tooltip scan answers both; asking the two questions separately would scan every bound slot
twice per build. Callers that only want the first answer ignore the second, as they always did.

### And then they are shown, not hidden

With the detection fixed, bound items would have vanished completely — which is *not* what was
asked for. The browser is meant to account for what is in the bags. So they are kept and collected
into a bucket rendered under `Not Profitable` and above `Ignore`, with their icons dimmed, skipping
the method split and the profit-margin filters alike (both are questions about how best to sell
something, and the answer for a bound item is "you cannot"). Their tiles do nothing when clicked,
on either button: the sell slot would refuse the item and the batch cannot post it, so doing
nothing is the honest response.

`Ignore` keeps its "dead last" place — it is the bucket the seller filled by hand.

**Grey trash stays filtered.** It is not sellable *and* not interesting, which is the pair that
earns an item its exclusion.

### 4b. Round two: the filter was looking for the wrong strings

**Owner, 2026-08-23:** *"Also some items have BOP and Realmbound status that should also go to the
bottom with soulbound items"*, with two item links. Those links answered it, and the answer did not
need the client:

| | `db.ascension.gg` tooltip | why it leaked |
|---|---|---|
| [22523](https://db.ascension.gg/?item=22523) "Insignia of the Dawn" | `Binds when picked up` | see the two structural fixes below |
| [134985](https://db.ascension.gg/?item=134985) "Personal Bank" | `Binds to account` | **nothing here ever checked that global** |

The second is a plain miss: the test knew `ITEM_SOULBOUND`, `ITEM_BIND_ON_PICKUP` and
`ITEM_BIND_QUEST`, and account-bound items are not any of those. `ITEM_BIND_TO_ACCOUNT`,
`ITEM_ACCOUNTBOUND` and `ITEM_BNETACCOUNTBOUND` are on the list now.

"Realmbound" is Ascension's own status and **has no global in 3.3.5 at all**, so it is a literal
(both spellings, `Realmbound` and `Realm Bound`), and matching is case-insensitive.

Two structural changes came with it, either of which could hide a status the marker list already
knows:

- **Both tooltip columns are read.** Blizzard puts binding on the left; this is a custom server,
  and the right-hand column of a two-column tooltip is the cheapest place to bolt a custom status
  on. A column never read is a status that leaks silently.
- **The scan starts at line 2.** Line 1 is the item NAME, and an item *called* "Soulbound Keepsake"
  is not soulbound — it just says so. That false positive would have hidden a **sellable** item,
  which is the more expensive direction to be wrong in.

**What is deliberately NOT on the list, and this is the whole safety property:** `ITEM_BIND_ON_EQUIP`
("Binds when equipped") and `ITEM_BIND_ON_USE` ("Binds when used"). Those are the ordinary state of
most gear worth selling. A looser test — anything containing "bound", say — would empty the browser
of exactly the items it exists for, silently, and only for the player whose bags hold them.
`bound-scan-smoke.lua` asserts both negatives; they are the reason it exists.

### 4d. What the first real `/atrbound` dump changed

The owner ran it over 99 bag items on 2026-08-23. Three things came back, and two of them were
corrections to guesses made above.

**Ascension redefines stock globals rather than adding new ones.** The dump prints the marker list
it is actually using, and that list read:

```
Soulbound | Binds when picked up | Quest Item | Binds to realm | Realm Bound | Realmbound | Realm Bound
```

So on this client `ITEM_BIND_TO_ACCOUNT` is **"Binds to realm"** and `ITEM_ACCOUNTBOUND` is
**"Realm Bound"** — and `ITEM_BNETACCOUNTBOUND` does not exist at all, which the `add` guard
swallowed silently, as designed. The claim in §4b that Realmbound "has no global at all" was
**wrong**: reading the two account globals already covered every realm-bound item in the dump
(scourgestones, Realm Bank, Personal Bank). The two literals are kept as belt-and-braces — the
unspaced spelling, which no global carries, and a hedge against a client without the redefinition —
and the comment in the source now says so. `bound-scan-smoke.lua` uses the **real** strings, because
a test against the stock ones would pass while the addon failed on the only realm it runs on.

**A marker now has to START a line.** The dump caught this:

```
[2:6] Personal Bank   ->   BOUND - bottom bucket
     2L  Realm Bound                                          <== MATCHED
     4L  "...You can put soulbound items into bank."          <== MATCHED
```

Line 4 is *flavour text*. That item was bound anyway, so the verdict was right by luck — but the
same sentence on a tradeable item would have hidden it from the browser with no way for the seller
to see why. Every genuine binding line across all 99 items is the marker and nothing else, so
matching is anchored to the start of the trimmed line. That also demotes the line-1 name skip from
the only guard to a second one.

**And the reported item needed a second source entirely.** Item 22523's tooltip *in the bag* is one
line long:

```
[0:6] Insignia of the Dawn   ->   sellable
     1L  Insignia of the Dawn
```

No bind line to match — a slot scan cannot find what the slot does not have. So there is now a
second question, and it is a different one: not *"is the copy in this slot bound"* but *"does this
ITEM bind on pickup at all"*. `Atr_Sell_ItemDefIsBound(link)` answers it with `SetHyperlink`, which
draws the item's definition with no ownership context. On 3.3.5 that settles it — a bind-on-pickup
item binds when it is looted, so if it is in your bags it is bound whatever its slot tooltip says.

**That one *is* cacheable by link**, which is the only reason it can afford to run: it is a property
of the item, exactly as quality is, unlike the slot scan whose entire bug history (§4a) is people
caching it this way. One lookup per distinct item per session. It cannot false-positive on what
matters either — a definition tooltip says "Binds when equipped" for BoE gear, which is not a
marker. The one rule it must keep is the same one `Atr_Sell_ItemIsGrey` keeps: **never remember a
verdict read off a tooltip that had not arrived**, or the item stays in the selling categories until
a reload.

If item 22523's *definition* tooltip also carries no bind line, then this realm does not mark it
bound, the database page is stale, and the auction house will take it — the next dump says which,
because `/atrbound` now prints the item's own tooltip whenever the slot's had nothing to say.

### 4c. `/atrbound` — reading the tooltips this repo cannot see

An in-game diagnostic is the last resort here, and the reason is stated at the call site: **a custom
server's tooltip strings are not knowable from outside its client.** Two of the markers above came
from item pages and one from the owner's own wording; none of that is the client, and an item whose
status line has never been seen leaks through without a sound. The next one should cost a paste,
not another round trip.

```
/atrbound            every item in your bags
/atrbound insignia   only items whose name contains "insignia"
```

It prints, per bag slot: the item, the verdict the browser will give it
(`sellable` / `BOUND - bottom bucket` / `GREY - hidden entirely`), every tooltip line in both
columns, and `<== MATCHED` against whichever line made it bound. When the slot's tooltip said
nothing it then prints the **item's own** tooltip (`SetHyperlink`) under a `def` prefix, since a
disagreement between those two is the whole answer. It ends with the marker list itself. So an item
that says `sellable` but should not shows the line that ought to have matched, sitting right there
next to a list that does not contain it — and if neither tooltip carries such a line, that is the
answer too: this realm does not mark that item bound.

**Output goes to the copy/paste box** (`Atr_An_ShowDebugBox`, reused rather than rebuilt), never to
chat — chat text cannot be selected on this client, so a printed diagnostic can only come back as a
screenshot, and a screenshot of eight hundred tooltip lines is not evidence anybody can work from.

### The bucket is called "Bound" now

`Soulbound (n)` was accurate when soulbound was all it held. It now holds bind-on-pickup,
account-bound and realmbound items too, so the header is **`Bound - not sellable (n)`** — naming
the predicate rather than one of the several bind kinds under it. The tile field is `bound`, not
`soulbound`, for the same reason.

---

## 5. Interaction

| gesture | what happens |
|---|---|
| left-click an inventory tile | unchanged — loads the item into the sell slot |
| **right-click an inventory tile** | queues it into Batch Post |
| right-click a queued tile again | takes it back out |
| click a queued row in the right column | takes it back out |
| right/left-click a Bound tile | nothing |
| **Batch Post** | posts the queue; a second click cancels |
| **Clear** | empties the queue |

Right-click inside the browser used to be a second copy of the left click, so **no behaviour was
lost.** Right-click in the *actual bags* (`Atr_ContainerFrameItemButton_OnClick`) is untouched and
still loads to the sell slot.

A queued tile gets a green wash. Without it, a right-click that queued something and one that did
nothing look identical, and the queue is off in the other column.

---

## 6. What was checked

`luac5.1 -p` clean on every changed file; `Auctionator.xml` parses. All eleven offline suites pass.

**`batch-price-smoke.lua` is new, and the house rule says a new harness needs a reason.** The reason
is precedent: this feature's price now comes out of a raw scan result set by variant key and by
owner, and same-name variants have escaped this addon three times already — `sell-variant-smoke.lua`
exists in as many words because "the same symptom has now escaped twice". Both functions are pure
over an array whose order nobody controls, so the orders are enumerated rather than reasoned about.
It stubs `GetItemInfo`, `UnitName`, `Atr_VariantKey`, `Atr_CalcUndercutPrice`, `Atr_GetAuctionPrice`
and one `F.GetResults`, loads the real file with `loadfile` and hands it a fake `addonTable` — no
frames, no engine, no post. It must not grow past that. All 25 passed first run.

`bound-scan-smoke.lua` is also new. It loads the **real** `Auctionator.lua` — that file runs under
bare lua5.1 with only `time` and `date` stubbed — so it drives the actual matcher rather than a
transcription of the marker list, which would be worth nothing. 48 assertions, including the real
strings and the real flavour-text line from the owner's dump. It carries a ~30-line tooltip stub,
the one place this suite is allowed to grow: `Atr_Sell_ItemDefIsBound` caches **by link**, which is
the exact shape of every bug §4a describes, and the rule that makes it safe there needs pinning.

**Nothing here is verified in game.** The parts most worth a look on first run, in order:

1. **`/atrbound insignia` first.** It now prints the item's *own* tooltip when the slot's says
   nothing. If that shows `Binds when picked up`, the fix above catches it; if it shows nothing
   either, this realm does not mark item 22523 bound and the database page is stale — in which case
   the auction house will take it and there is nothing to fix.
2. Does a run actually advance — scan comes back, item posts, next scan starts? That chain is the
   whole feature and it is the one thing offline work cannot check.
3. Does the progress bar creep during a scan rather than only between items, and does the title
   come back when the run ends?
4. How long is a realistic queue? One throttled query per distinct name is the floor; if that is
   painful, the lever is scanning by name *group* rather than per name.
5. Does the batch column land where §2 says, and does the inventory's scroll bar clear it?
