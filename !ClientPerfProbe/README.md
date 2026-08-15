# Client Perf Probe

Find out *what* is causing client stutter before trying to fix it. Per-addon and
per-event frame-time spike attribution, with a copy/paste report.

**Version 0.2.0 · Interface 30300 (WotLK 3.3.5 / Ascension)**

## What it does

A driver frame's `OnUpdate` diffs `debugprofilestop()` to get true whole-frame
time. When a frame exceeds the threshold (50 ms by default, ~3 dropped frames at
60 fps) the spike is recorded into a ring buffer along with its context — recent
events, heap delta, combat-log and streaming rates, zone-in proximity, whether
you were dragging a window, and per-tag CPU from any addon that opted into the
cooperative meter.

Attribution of *who* comes from a periodic sampler, not from scanning inside the
spike, so the hot path stays lean — measurement perturbs what it measures.

It also profiles the login cascade: every `ADDON_LOADED` is stamped in ms and KB,
giving a per-addon initial-load cost and a login timeline.

Reads out three ways: a copy/paste report window (`/cpp`), an at-a-glance
window and minimap button (`/cpp ui`), and a dump into SavedVariables
(`/cpp save`) you can attach to a bug report.

## Installing

Copy the `!ClientPerfProbe` folder into `Interface\AddOns`. **Keep the `!`** — on
3.3.5 addons load alphabetically by folder name and the `!` prefix (the standard
`!BugGrabber` trick) forces this one to load first, which is what lets it
attribute nearly the whole load cascade. There is no load-priority field in a
`.toc`. `/cpp load` self-verifies it worked: a small `pre=` figure and a high
addon count means it got there early.

## Commands

`/cpp` (or `/perfprobe`)

| Command | Effect |
| --- | --- |
| `/cpp` | Open the copy/paste report window |
| `/cpp ui` | Open the at-a-glance window (same as left-clicking the minimap button) |
| `/cpp minimap` | Show/hide the minimap button |
| `/cpp stat` | Quick summary in chat |
| `/cpp load` | Initial-load timeline + per-addon load cost |
| `/cpp matrix` | API support matrix for this client |
| `/cpp thr <ms>` | Set the spike threshold |
| `/cpp gc` | Force one full GC and measure the pause |
| `/cpp mem` | Bounded `_G` walk ranking the largest memory globals |
| `/cpp profile on\|off` | Arm/disarm `scriptProfile` (reloads the UI) |
| `/cpp prewarm` | Frontload prototype — warm windows now (`list` / `add <Frame>` / `on` / `off`) |
| `/cpp backdrop <Frame>` | Read a window's backdrop, to compare a laggy one against a smooth one |
| `/cpp backdroptest` | Spawn A/B/C/D drag frames to isolate a backdrop as the stutter cause |
| `/cpp constructtest` | E/F/G/H drag frames (backdrop constant) to isolate dropdown children |
| `/cpp save` | Stamp the report into SavedVariables, then `/reload` and attach the file |
| `/cpp clear [min]` | Wipe captured spikes and counters (`clear <min>` trims recent spikes only) |

## Cooperative profiling API

Any addon can opt into per-tag CPU attribution with no dependency, via the global
`ClientPerfProbe`:

```lua
local CPP = ClientPerfProbe
if CPP then
    frame:SetScript("OnEvent", CPP.Wrap("MyAddon:OnEvent", handler))
end
```

`Wrap`, `Measure`, `Enter`, `Leave` and `Add` are available. The API shape is v0
(proposed) — treat it as unstable until the ergonomics settle.

## Saved variables

`ClientPerfProbeDB` — settings plus the spike ring buffer. The ring persists
across `/reload` so `/cpp save` can flush it to disk, which means a capture taken
without a `/cpp clear` mixes this session's spikes with restored ones. Those are
marked `old=1` so a report is never misread.

## Notes

- `scriptProfile` is locked from Lua on Ascension — the client resets it to 0 on
  load. The addon detects this once, records it, and commits to the memory-delta
  and event-rate fallbacks rather than retrying. That's a finding, not a failure.
- This is a **measurement** tool. The pre-warm feature is an explicit prototype
  and is off by default, so a normal session is never perturbed. Measure first.
