# Batch Post — the SELL tab's right-hand column

Built 2026-08-22 (BACKLOG item 12). Everything here is read from source or reasoned from it;
the client cannot be run here, so **nothing below is verified in game.**

The request, verbatim: *"On the Auctionator sell tab, divide the inventory area in half and make
the new (right half) called batch post, add items from inventory section into batch by right
clicking them. Press Batch Post button, sells at automatic set price discount, and whatever
duration is currently set. Also let's keep all soulbound items at the bottom, they are mixed in
here and there."*

Two separate things, and the second one turned out to be a bug rather than a preference. They are
written up in that order.

---

## 1. Where the code is

| | |
|---|---|
| `Auctionator-Finder-Ascension/AuctionatorBatchPost.lua` | **new.** The queue, the panel, the post driver. Loads last in the `.toc`. |
| `Auctionator.lua`, `Atr_ApplySellExpandedLayout` §3 | splits the band; calls `Atr_BP_Layout` |
| `Auctionator.lua`, `Atr_ResetSellExpandedLayout` | calls `Atr_BP_Unplace` |
| `Auctionator.lua`, `Atr_SB_Item_OnClick` | right-click queues / unqueues |
| `Auctionator.lua`, `Atr_SB_Build` | soulbound bucket, green wash on queued tiles, tail-calls `Atr_BP_Build` |
| `Auctionator.lua`, `Atr_Sell_ItemIsGrey` / `Atr_Sell_ItemIsBound` | the soulbound fix (§4) |

**No new saved variable.** The queue is session-only on purpose — see §3.

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

### The price

"Automatic set price discount" is read as: the price the SELL tab would have recommended, computed
without the part that needs a live scan.

```
buyout per item  = Atr_CalcUndercutPrice (Atr_GetAuctionPrice (name, variantKey))
start  per item  = Atr_CalcStartPrice (buyout)          -- AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT
stack prices     = both of the above x the stack size actually in the sell slot
duration         = UIDropDownMenu_GetSelectedValue (Atr_Duration), read once at run start
```

That is `Atr_UpdateRecommendation`'s arithmetic line for line. It is variant-keyed for the reason
`Atr_SB_BestMethod` is (BACKLOG item 4): a name-only read answers the `ATR_PV_ANY` slot, which only
a full scan writes.

**The one honest difference from posting by hand, stated rather than hidden.** The sell box runs a
fresh query per item and prices against the listings that come back, so it knows which of them are
*yours* and refuses to undercut those (`basedata.yours`). A batch of thirty items cannot afford
thirty queries on the throttled channel, so this prices off `Atr_GetAuctionPrice`'s cascade, which
is name/variant-keyed and carries no owner. **Batch-posting the same item twice without a scan in
between therefore undercuts your own listing by one step.** `Scan Inventory`, directly under the
left column, is the fix and is one click away.

**An item with no known price is never guessed at.** It stays in the queue, greyed, with "no price"
where its total would be, and the run skips it. Posting at a made-up price is worse than not
posting.

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
`Scan Inventory` uses.

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

## 4. The soulbound bug

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

With the detection fixed, soulbound items would have vanished completely — which is *not* what was
asked for. The browser is meant to account for what is in the bags. So they are kept and collected
into a **`Soulbound` bucket** rendered under `Not Profitable` and above `Ignore`, with their icons
dimmed, skipping the method split and the profit-margin filters alike (both are questions about how
best to sell something, and the answer for a bound item is "you cannot"). Their tiles do nothing
when clicked, on either button: the sell slot would refuse the item and the batch cannot post it,
so doing nothing is the honest response.

`Ignore` keeps its "dead last" place — it is the bucket the seller filled by hand.

**Grey trash stays filtered.** It is not sellable *and* not interesting, which is the pair that
earns an item its exclusion.

---

## 5. Interaction

| gesture | what happens |
|---|---|
| left-click an inventory tile | unchanged — loads the item into the sell slot |
| **right-click an inventory tile** | queues it into Batch Post |
| right-click a queued tile again | takes it back out |
| click a queued row in the right column | takes it back out |
| right/left-click a Soulbound tile | nothing |
| **Batch Post** | posts the queue; a second click cancels |
| **Clear** | empties the queue |

Right-click inside the browser used to be a second copy of the left click, so **no behaviour was
lost.** Right-click in the *actual bags* (`Atr_ContainerFrameItemButton_OnClick`) is untouched and
still loads to the sell slot.

A queued tile gets a green wash. Without it, a right-click that queued something and one that did
nothing look identical, and the queue is off in the other column.

---

## 6. What was checked

`luac5.1 -p` clean on both changed files and the new one; `Auctionator.xml` parses. All nine offline
suites still pass (20 + 14 + 3 + 14 + 27 + 68 + 114 + 25 + 20) — none of them loads `Auctionator.lua`,
so they are a no-regression check on the rest of the addon rather than cover for this change.

**Nothing here is verified in game.** The parts most worth a look on first run, in order:

1. Does the batch column land where §2 says, and does the inventory's scroll bar clear it?
2. Does one post really empty the sell slot on this server, i.e. does the driver advance at all?
3. Do the two buttons sit on the divider rather than under it?
4. Is the `Soulbound` bucket now complete — nothing bound left up in the selling categories?
