# The probe was measuring itself — the 5-second sampler

**Status:** diagnosed from a live capture (2026-08), fixed in `!ClientPerfProbe` 0.2.1,
**confirmed in game.** A 202-second post-fix capture in the same spot came back
`spikes=0^shown=0` at `thr=50`, against 27 before. The 5-second grid is gone.

The same capture measured the walk directly for the first time:
`P^int=30.0^live=1^last=30.7^max=30.9^n=7^over=0` — **~31 ms** on a 110 MB heap, not
the ~50 ms estimated below from the spike widths. The estimate was high because a
spike's `dt` spanned the walk *plus* the rest of that frame: ~31 ms of walk on top of a
~20 ms city frame lands squarely in the 50.3–56.3 ms band that was observed, so the
arithmetic closes. `over=0` — the walk no longer crosses the spike threshold at all.

## The report that started it

The owner turned off every custom addon in this repo and still saw small, regular
stutters while standing in Ironforge. The capture (`thr=50`, `attr=mem`, heap
106,615 KB, 22 addons, ~24 h client uptime):

```
S^i=15^t=86636.3^dt=50.4^cmb=0^cleu=20^dh=5^sus=?^zone=Ironforge^ev=CHAT_MSG_CHANNEL,...
S^i=14^t=86621.3^dt=56.3^cmb=0^cleu=0^dh=29^sus=?^zone=Ironforge^ev=CHAT_MSG_CHANNEL,...
S^i=13^t=86616.3^dt=51.0^cmb=0^cleu=20^dh=3^sus=?^zone=Ironforge^ev=CHAT_MSG_CHANNEL,...
```

Twenty spikes, almost all `sus=?`, all in a narrow band just over the threshold.

## What gave it away

**The timestamps are on an exact 5-second grid.** Taking `t mod 5`:

| spikes | `t mod 5` |
| --- | --- |
| 86581.3 86586.3 86596.3 86606.3 86611.3 86616.3 86621.3 86636.3 | 1.3 |
| 86666.4 86676.4 86686.4 86691.4 86696.4 86721.4 86726.4 | 1.4 |
| *(reload at ~86738)* | |
| 86798.1 86813.1 86848.1 | 3.1 |

Fifteen consecutive pre-reload gaps — 5, 10, 10, 5, 5, 5, 15, 30, 10, 10, 5, 5, 25, 5 —
every one a multiple of five, no exceptions. That is a fixed-period timer, and the
missing ticks are ticks whose cost came in a millisecond or two *under* the threshold.

**The phase resets across the reload** (1.3/1.4 → 3.1). `GetTime` is monotonic since
client start and survives a `/reload`, so a server-side broadcast would have kept its
phase. An `OnUpdate` accumulator seeded at UI load is exactly what shifts.

**The probe had exactly one 5-second timer**, `DEFAULTS.sampleSec = 5` driving
`ns.Attrib.sample()`, which calls **`UpdateAddOnMemoryUsage()`** — a full Lua-heap walk
that attributes memory per addon — then loops all 22 addons. The header's `attr=mem`
proves the walk really runs here rather than being stubbed like `scriptProfile`.

**And the driver stamped `lastClock` *before* running it:**

```lua
local dt = now - lastClock
lastClock = now                 -- <- baseline taken here
...
if sampleAccum >= sampleSec then
    sampleAccum = 0
    if ns.Attrib then ns.Attrib.sample() end   -- <- ~50 ms spent AFTER the baseline
end
```

So the scan's cost fell into the **next** frame's `dt` and was captured as an
unattributed client stall — by the code that caused it.

## Four details that corroborate it

- **`dt` is pinned at 50.3–56.3 against `thr=50`.** A roughly fixed ~50 ms cost sitting
  right on the bar, which is also why ticks go missing.
- **The cost tracks heap size.** Pre-reload (24 h uptime, 106 MB heap): 15 spikes over
  29 ticks, about half crossing. Post-reload (fresh, smaller heap): 3 over ~25 ticks,
  about 12 %. That is the signature of an O(heap) walk, and it is not something a
  server broadcast or a chat flood would do.
- **`dh` is −2 to +38 KB and `cleu` is 0 or 1 event** on every one. `cleu` is a *rate*,
  so `cleu=20` over a 50 ms frame is one combat-log event. Not memory, not combat.
- **`ev=CHAT_MSG_CHANNEL` on all of them is noise**, and `Report.lua`'s `NOISE` table
  exists precisely because chat is the loudest ambient event in a city and buries the
  real fingerprint. It named nothing here.

Two spikes in that capture were *not* the sampler and should be read separately:
`i=23` (`dt=670.3`, `dh=+2903`, `sus=ALLOC`) and `i=24` (`sus=ZONE`) are the `/reload`
itself.

## What was ruled out

**Chat volume.** The same capture shows `CHAT_MSG_CHANNEL` at **109.3/s — 14,231
messages in a 130 s window**, accounting for essentially all of the 19.2 KB/s inbound.
That is abnormal and worth chasing on its own, but it is *continuous*: it cannot produce
a clean 5-second grid. Chased separately and now solved — three addon data channels, see
`CHAT-FLOOD.md`. It is a real ambient tax though,
including on the probe's own `RegisterAllEvents` frame (`Events.lua`).

**The server update.** Latency was flat at 122–128 ms with `out=0.1` throughout. Nothing
in the capture moves with it.

**"Only when standing still."** No mechanism was found: the accumulator sums `elapsed`
and fires every 5 s regardless of movement. The likely explanation is perception — a
50 ms hitch is visible against a smooth static scene and disappears into the frame
pacing of running through a city. **Still unconfirmed**, and now unfalsifiable from this
angle: the spikes are gone, so there is nothing left to correlate with movement. Left
here as an open loose end rather than a solved one.

## The fix (0.2.1)

1. **`sampleSec` 5 → 30**, with a SavedVariables migration off the old value. Safe to
   apply unconditionally today because `/cpp sample` did not exist when a `5` could have
   been written, so nobody chose it deliberately.
2. **The scan runs only while something reads it live** — the at-a-glance window — plus
   one scan on the *explicit* report paths (`/cpp`, `/cpp save`). With the window closed
   the probe now costs nothing per frame beyond its event counter. A ~50 ms stall on a
   command you typed is not a mystery spike; one every 5 seconds while you play is.
   The on-demand scan deliberately sits in `refreshAttribution()` and **not** in
   `buildReportData()`, because the at-a-glance window calls the latter from its own
   5-second poll — putting a full-heap walk back on a 5-second timer is the bug.
   One consequence to know: the first scan of a session only establishes a baseline,
   so its `O` rows are all zero. The `P` row carries `base=1` when that is what you are
   looking at; the next report has real deltas.
3. **`runSampler()` re-baselines `lastClock` and `lastHeap` *after* the walk**, so the
   cost can never be billed to the client again. This is the part that matters: without
   it, 1 and 2 would only have made the artefact rarer and harder to spot.
4. **The cost is reported, not hidden** — a new `P` row:
   `P^int=30.0^live=0^last=52.4^max=58.3^n=12^over=7^win=124.0[^base=1]`. A probe that conceals
   what it spends is contaminating, not measuring. `win=` is the window the `O` rows
   above it actually cover, which is no longer the header's `win=` now that the scan is
   on demand.
5. **`/cpp sample <sec>`** (`0` = off), plus a glossary entry so the at-a-glance window
   explains it in plain English.

## Confirming it in game

**Done, 2026-08 — both checks passed.** A 202 s capture standing in the same spot with
the at-a-glance window open returned `spikes=0` at `thr=50` (27 before), and the `P` row
read `last=30.7 max=30.9 n=7 over=0`. Not one of the seven walks crossed the threshold,
and no 5-second grid survived. Kept here as the record of what was run:

1. `/cpp clear`, then `/cpp thr 25`. Stand still two minutes and read the spikes.
   **Before the fix** the grid would tighten to a spike every 5 s with no gaps; **after**
   it, no 5-second grid should appear at all.
2. Open the at-a-glance window, leave it up 2 minutes, `/cpp` and read the `P` row.
   `last`/`max` are the real cost of the walk on this client and this heap.
3. Anything still landing on an exact 5-second grid after that is **not** ours, and the
   next suspects are Details' and WeakAuras' own periodic timers.

## The rule this leaves behind

Any periodic work the probe adds to the frame loop must (a) be gated on someone
actually reading it, (b) re-baseline the driver's clock and heap after it runs, and
(c) appear in the report as its own cost. Measurement perturbs — the README has said so
since the beginning; this is what it looks like when the warning is not followed
through into the code.
