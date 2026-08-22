# Client Perf Probe

Find out *what* is causing client stutter before trying to fix it. Per-addon and
per-event frame-time spike attribution, with a copy/paste report.

**Version 0.2.2 · Interface 30300 (WotLK 3.3.5 / Ascension)**

## What it does

A driver frame's `OnUpdate` diffs `debugprofilestop()` to get true whole-frame
time. When a frame exceeds the threshold (50 ms by default, ~3 dropped frames at
60 fps) the spike is recorded into a ring buffer along with its context — recent
events, heap delta, combat-log and streaming rates, zone-in proximity, and
whether you were dragging a window.

Context comes from a periodic sampler and from cheap reads on the spike frame
itself, never from scanning inside the spike — the hot path stays lean, because
measurement perturbs what it measures.

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
| `/cpp sample <sec>` | Per-addon attribution scan interval, `0` to turn it off — see *What the probe costs you* |
| `/cpp gc` | Force one full GC and measure the pause |
| `/cpp mem` | Bounded `_G` walk ranking the largest memory globals |
| `/cpp backdrop <Frame>` | Read a live window's backdrop, to compare one window's chrome against another |
| `/cpp save` | Stamp the report into SavedVariables, then `/reload` and attach the file |
| `/cpp clear [min]` | Wipe captured spikes and counters (`clear <min>` trims recent spikes only) |

## Saved variables

`ClientPerfProbeDB` — settings plus the spike ring buffer. The ring persists
across `/reload` so `/cpp save` can flush it to disk, which means a capture taken
without a `/cpp clear` mixes this session's spikes with restored ones. Those are
marked `old=1` so a report is never misread.

## Notes

- **Naming a chat flood.** In a city, `CHAT_MSG_CHANNEL` is routinely the busiest
  event the client handles, and the `R` rate row can only say so — not which channel.
  The `C` rows break it down per channel: message rate, KB/s of your inbound bandwidth,
  distinct senders, the loudest one, and `j=` for whether you are actually joined to
  that channel. `j=0` means traffic is arriving from a channel you did not join, which
  means an addon joined it for you. Message text is never stored — the report is a blob
  you paste in public. Background: `management/addons/clientperfprobe/CHAT-FLOOD.md`.

- **What the probe costs you.** Answering "which addon moved memory" means calling
  `UpdateAddOnMemoryUsage()`, which walks the entire Lua heap. On a played-in session
  (106 MB heap, 22 addons) that walk measured **~50 ms** — long enough to feel. Until
  0.2.1 it ran every 5 seconds and the driver stamped its frame clock *before* running
  it, so the cost landed in the next frame's `dt` and the probe recorded its own scan
  as an unattributed ~50 ms spike, on an exact 5-second grid, forever. Now the scan
  runs only while the at-a-glance window is open (the one thing reading it live) plus
  once when you build a report, its cost is timed and printed as the `P` row, and the
  clock and heap baselines are re-stamped after it so it can never be billed to the
  client again. Tune with `/cpp sample <sec>`. Full account:
  `management/addons/clientperfprobe/SAMPLER-COST.md`.

- **There is no CPU attribution, by design.** `scriptProfile` is locked from Lua
  on Ascension — the client resets it to 0 on load — which takes the whole
  `GetAddOnCPUUsage` family with it. The only way around that was a cooperative
  meter every addon had to be hand-instrumented for; that isn't feasible to
  maintain, so it's gone. The matrix still reports `cvar:scriptProfile` as the
  record of the finding. Spikes are attributed by what they coincided with
  (memory, combat-log rate, zone-in, window-open, drag) and by the load profile,
  which is the one genuine per-addon channel this client leaves open.
- This is a **measurement** tool: nothing here changes client behaviour on its
  own, so a normal session is never perturbed. Measure first, then fix in the
  addon the capture names.
