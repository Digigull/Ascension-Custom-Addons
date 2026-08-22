# The SELL tab's frame cost, and the one auction query channel

Written 2026-08-23 against the owner's report: *"I got disconnected in game twice in a row when
using the Sell tab on Auctionator and see the same spike occur multiple times in a row, only did it
once this round because I crash on a DC from the server on this client"*, with a `!ClientPerfProbe`
export attached.

**Read the split in this document before reading the fixes.** One half is measured, from the
owner's own probe report and from the source. The other half — the disconnect — is *reasoned*, and
the client cannot be run here to close it. Both are written up because the fixes for them are in
the same three files, but they are not equally well established and this file says which is which.

---

## 1. What the probe actually says

The header and the four spike lines, trimmed:

```
CPP1^...^win=38^thr=50^spikes=4^shown=4
M^api=collectgarbage(count)^st=ok^d=123417KB
S^i=4^t=68603.8^dt=304.9^dh=33^   ev=AUCTION_ITEM_LIST_UPDATE,CHAT_MSG_CHANNEL,CURSOR_UPDATE,NEW_AUCTION_UPDATE
S^i=3^t=68603.0^dt=114.1^dh=14^   ev=CHAT_MSG_CHANNEL
S^i=2^t=68601.3^dt=79.6^ dh=311^  ev=CHAT_MSG_CHANNEL,GLOBAL_MOUSE_UP,GLOBAL_MOUSE_DOWN
S^i=1^t=68593.8^dt=157.3^dh=-5656^sus=GC^ev=AUCTION_HOUSE_SHOW,...^open=auction
R^ev=CHAT_MSG_CHANNEL^n=2655^ps=70.2
R^ev=AUCTION_ITEM_LIST_UPDATE^n=31^ps=0.8
```

`win=38`, so the `R^` rates are counts over the last 38 seconds. Reading it in order:

| | |
|---|---|
| i=1 | the auction house opening. A garbage collection, not our cost. |
| i=2 | **a click** (`GLOBAL_MOUSE_DOWN/UP`), 79.6 ms, **311 KB allocated on one frame**. |
| i=3 | 114 ms with nothing in `ev` but channel chat, which at 70/s is background noise. |
| i=4 | 305 ms on `AUCTION_ITEM_LIST_UPDATE`, with `NEW_AUCTION_UPDATE` and `CURSOR_UPDATE` alongside — an item went into the sell slot and its price query came back. |

Half a second of stall for one item put up for sale, and the owner reports the pattern repeating.
The two numbers worth keeping are **311 KB on a single click frame** and a **123 MB Lua heap**.

---

## 2. The measured half: the inventory browser rebuilt itself out of new frames every time

`Atr_SB_Build` (`Auctionator.lua`) rendered the inventory browser by **creating every widget from
scratch on every rebuild** and throwing the previous set away:

```lua
local function Atr_SB_Clear()
    for _, w in ipairs(gSB_Widgets) do
        if (w and w.Hide) then w:Hide(); end
        if (w and w.SetParent) then w:SetParent(nil); end   -- <-- this does not free anything
    end
```

**A frame created on 3.3.5 can never be destroyed.** `Hide()` hides it, `SetParent(nil)` orphans it,
and it stays in the client's frame list until you log out. There is no `:Destroy()`; this is the
oldest rule in WoW UI work, and `AuctionatorBatchPost.lua` already states it in one line next to
its own `gRowPool` — *"recycled queue rows; frames cannot be destroyed"*. The column next door got
this right and the inventory column did not.

Per rebuild, per sellable bag item: one `Button`, one background `Texture`, a `FontString` for the
stack count, and a second `Texture` if the item is queued for a batch. Plus a `Frame` and a
`FontString` for every category heading and every method sub-heading. **A hundred sellable items is
roughly four hundred objects, created and abandoned, per rebuild** — which is where the 311 KB on
one click frame comes from, and part of where a 123 MB heap comes from over a session.

And the browser rebuilds often. Every bag change (throttled to 1/s, which during a batch run means
*once a second for the length of the run*), every tile right-click, both ends of a Scan Inventory
run, both ends of a Batch Post run, every ignore toggle, and the expanded-layout apply path.

**Fix: pool them.** `gSB_TilePool` / `gSB_HeadPool`, handed out in order by `Atr_SB_AcquireTile` and
`Atr_SB_AcquireHeading`, with `Atr_SB_Clear` reduced to a Hide loop and two counters. The pools grow
to the largest bag load seen in the session and then stop. The one thing this asks of the render
code is stated at the call site: **a recycled tile still carries the last item's fields**, so every
one of them is set unconditionally — including the two that used to be set only in their true case,
the bound dimming (`SetVertexColor`) and the green batch wash.

### 2b. And it rendered a tooltip per bag item, every time

The other half of a rebuild's cost is `Atr_IsItemSellableOnAH`, which for every non-grey bag item
calls `Atr_Sell_ItemIsBound` — a full `AtrScanningTooltip:SetBagItem` render plus a line walk. That
is cheap once and expensive a hundred times, and the browser asks about every slot on every rebuild
while the bags have not moved between most of them.

**Fix: `gSB_SlotCache`, a memo of the VERDICT keyed `"bag:slot"`.** A hit must also match the link
that was in the slot when the verdict was taken, and the whole memo is dropped on `BAG_UPDATE` —
**at the top of `Atr_SB_BagUpdate`, above its combat / taxi / loading bail-outs and above its
once-a-second throttle**, so a bag change whose *rebuild* is deferred still invalidates the memo.
That is also what covers the case the link check cannot: an item that binds in place, same slot,
same link, which fires a bag update of its own.

**`Atr_Sell_ItemIsBound` itself is left uncached**, which is the rule its own block comment lays
down and the whole of its bug history (`BATCH-POST.md` §4). This caches the answer the browser got,
not the scan.

---

## 3. The reasoned half: two drivers, one auction query channel

**This section is a mechanism, not a measurement. Nothing below was reproduced here.**

There is exactly one auction query channel — `QueryAuctionItems`, gated by `CanSendAuctionQuery`,
answered by `AUCTION_ITEM_LIST_UPDATE` — and **the answer does not say whose query it belongs to.**
Two drivers paging at once therefore eat each other's pages: each sees a batch it did not ask for,
calls it a duplicate, and re-queries. `AuctionatorAnalysis.lua`'s pump already states the
consequence in one line — *"a second one racing it is how you get duplicate pages and
disconnects"* — and upstream Auctionator carries the same worry twice in the form of
`zc.UTF8_Truncate (queryString, 63); -- attempting to reduce number of disconnects`.

The SELL tab is where two of them meet in ordinary use:

| driver | what starts it |
|---|---|
| the pane's `AtrSearch` | dropping an item in the sell slot, or clicking an inventory tile — `Atr_OnNewAuctionUpdate` → `gSellPane:DoSearch` |
| the Finder engine | `Scan Inventory`, and every distinct name in a Batch Post run |

Nothing stopped them overlapping. A Batch Post run holds the channel for **minutes**, and clicking
a tile during one started a second driver on top of it.

**Fix: the pane waits instead of racing.** Three small pieces:

- **`Atr_Finder_ChannelBusy()`** (`AuctionatorFinder.lua`) — that file owns three of the drivers
  (the tab scan, the exact-buy verifier, the group verifier), so the predicate lives there. Global
  rather than on `addonTable.Finder`, because `Auctionator.lua` predates that surface and does not
  take `addonTable`.
- **`Atr_Pane_ChannelBusy()`** (`AuctionatorPane.lua`) — the above **plus `Atr_BP_Running()` and
  `Atr_SB_ScanRunning()`. A run outlasts the engine's busy flag**: it takes the channel one *name*
  at a time and the engine is genuinely idle in the gaps, so asking only the engine would let the
  pane grab the channel mid-run and cost the run's next item its live price.
- `AtrPane:DoSearch` sets `searchPending` instead of calling `Start()` when the channel is taken,
  and **`Atr_Idle` starts it the moment the channel frees** (`AtrPane:ResumePendingSearch`, called
  above every one of `Atr_Idle`'s bail-outs, because a pane waiting for the channel is idle by
  every test those bail-outs make — its `processing_state` is still `KM_NULL_STATE`).

**Deferred, not skipped.** `DoSearch` sets the pane up completely either way; only the query waits.
The item's price arrives a few seconds later rather than not at all.

The mirror, for the drivers on the other side: **`Atr_Sell_QueryBusy()`** in `Auctionator.lua`, which
`Scan Inventory` and `Atr_BP_GoClicked` both now ask before starting. They refuse with *"the sell
pane is still searching — try again in a moment"* rather than deferring, because a pane search is
over in a second or two and both of those are things the player just clicked.

### What this does and does not claim

It removes a race that the codebase already names as a disconnect cause, and it removes the
repeated 300 ms stall from the frames where the client is also taking 70 chat messages a second.
**It is not a proven fix for the disconnect** — the client cannot be run here, and a server-side
drop cannot be reproduced from source. If the disconnects continue, the next thing to look at is
the rate itself rather than the overlap: how many `QueryAuctionItems` calls a Batch Post run makes
per second against whatever this realm's flood policy allows.

---

## 4. Files touched

| | |
|---|---|
| `Auctionator.lua` | the pools and `Atr_SB_Clear`/`Atr_SB_AcquireTile`/`Atr_SB_AcquireHeading`; `gSB_SlotCache` and `Atr_SB_FlushSlotCache`; `Atr_Sell_QueryBusy`; the `Atr_Idle` resume; the `Scan Inventory` guard |
| `AuctionatorPane.lua` | `Atr_Pane_ChannelBusy`, `searchPending`, `AtrPane:ResumePendingSearch` |
| `AuctionatorFinder.lua` | `Atr_Finder_ChannelBusy` |
| `AuctionatorBatchPost.lua` | `Atr_BP_GoClicked` asks `Atr_Sell_QueryBusy` |

`luac5.1 -p` clean; all eleven offline suites pass. Nothing here is verified in game — the pooling
and the memo are reasoned from the frame lifetime rules, and §3 is a mechanism, as it says.
