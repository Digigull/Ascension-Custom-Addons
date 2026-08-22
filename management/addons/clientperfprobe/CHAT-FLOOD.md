# The Ironforge chat flood — solved

**Status:** solved in game, 2026-08, and the fix is measured. Three addon data channels
were **99.6 %** of it; leaving them took `CHAT_MSG_CHANNEL` from **107.6/s to 0.5/s**.
The addon whose channels they are was already disabled and it changed nothing, because
**unticking a channel does not leave it** — that is the finding worth keeping.

One claim made along the way did **not** survive its own test: that the chat traffic was
essentially the whole inbound bandwidth. It was not, or `GetNetStats` had not settled.
The correction is under "What the fix did NOT do" and the original wording is struck
rather than quietly deleted.

This came out of the sampler investigation (`SAMPLER-COST.md`) as a *separate* issue. It
is not what caused the 5-second spike grid, and the two should not be conflated.

## The capture that named it

`!ClientPerfProbe` 0.2.2 added per-channel `C` rows. Standing in Ironforge, 202 s window,
FrostSeek **disabled**:

```
R^ev=CHAT_MSG_CHANNEL^n=21743^ps=107.6
C^r=1^chan=BBLC25C^id=8^n=9335^ps=46.2^kbps=8.5^snd=48^cap=1^top=Alkeii^topn=38^j=1
C^r=2^chan=FSK^id=1^n=6348^ps=31.4^kbps=0.9^snd=48^cap=1^top=Benskalle^topn=149^j=1
C^r=3^chan=FSK-EVT^id=7^n=5971^ps=29.5^kbps=0.9^snd=46^top=Sooty^topn=151^j=1
C^r=4^chan=Ascension^id=2^n=64^ps=0.3^kbps=0.0^snd=38^top=Tftf^topn=5^j=1
C^r=5^chan=Newcomers^id=3^n=22^ps=0.1^kbps=0.0^snd=16^top=Bricket^topn=2^j=1
C^r=6^chan=Trade^id=5^n=3^ps=0.0^kbps=0.0^snd=2^top=Cursified^topn=2^j=1
C^r=7^chan=LookingForGroup^id=6^n=0^ps=0.0^kbps=0.0^snd=0^j=1
C^r=8^chan=Zone^id=4^n=0^ps=0.0^kbps=0.0^snd=0^j=1
```

**The rows sum to exactly 21,743** — the same number the `R` row reports. Nothing is
unaccounted for, which is what makes the split below a measurement rather than a sample.

| | messages | rate | payload |
| --- | --- | --- | --- |
| `BBLC25C` + `FSK` + `FSK-EVT` | 21,654 | 107.1/s | 10.3 KB/s |
| everything humans said (`Ascension`, `Newcomers`, `Trade`) | 89 | **0.44/s** | ~0 |

Real conversation in a capital city ran at **26 messages a minute**. The other 99.6 % is
machinery.

## Reading the byte column

`kbps=` against `ps=` gives mean payload size, and it separates the two kinds of traffic
outright:

| channel | bytes/message | reading |
| --- | --- | --- |
| `FSK` | 29 | beacons — too small to be prose |
| `FSK-EVT` | 31 | beacons |
| `BBLC25C` | 188 | real payloads |

`FSK` and `FSK-EVT` are FrostSeek's (`github.com/ayro-CMD/FrostSeek`). All three carry
many distinct senders — `snd=48` on two of them, and `cap=1` says the probe's
distinct-sender cap was hit, so 48 is a floor and `top=` is only the loudest of the first
48 it tracked. Many senders each contributing a little is **peer-to-peer addon sync**:
every player running the addon broadcasts to the channel and every other player receives
it. Not one spammer, not a server broadcast.

Message bodies came to 10.3 KB/s against `in=20.7 KB/s` measured. **The inference drawn
from that at the time — that chat was essentially the entire inbound stream — was
wrong**, and the `/leave` test below disproved it. See "What the fix did not do".

## The actual root cause

**Disabling the addon does not leave its channels, and neither does unticking them.**

The owner had already disabled FrostSeek and unticked `FSK`, `FSK-EVT` and `BBLC25C` in
the channel list. All three still delivered 61 messages a second, and `j=1` on every row
confirms the client was still joined. The tickbox in that list controls whether a channel
is **drawn in a chat window** — not whether you are a member. Channel membership lives in
the client's saved chat config and persists across the addon being disabled, across
`/reload`, and across logout.

So while unticked and with the addon gone, you still pay:

- the bandwidth (~20 KB/s here),
- one `CHAT_MSG_CHANNEL` event per message, dispatched to **every** frame registered for
  it — every chat addon, every filter, and the probe's own `RegisterAllEvents` frame,
- at 107/s, forever, for messages nothing on your client will ever show you.

0.2.2's `disp=` field exists for exactly this: `j=1` with `disp=0` and a high `n=` is
"joined, invisible, and costing you every message".

## The fix

```
/leave FSK
/leave FSK-EVT
/leave BBLC25C
```

Expected: `CHAT_MSG_CHANNEL` drops from ~107/s to well under 1/s, and inbound from
~20 KB/s to near nothing while idle. Reversible with `/join <name>`; re-enabling
FrostSeek will rejoin its own two by itself.

### What the fix did, measured

A 65 s capture immediately after leaving all three:

```
R^ev=CHAT_MSG_CHANNEL^n=31^ps=0.5
C^r=1^chan=Ascension^id=2^n=15^ps=0.2^...^j=1^disp=1
C^r=2^chan=Newcomers^id=3^n=8^ps=0.1^...^j=1^disp=0
```

**107.6/s → 0.5/s, a 215× reduction**, and the three channels are gone from the list
entirely. That is real CPU removed: one `CHAT_MSG_CHANNEL` dispatch per message to every
frame registered for it, 107 times a second, now gone.

### What the fix did NOT do — a correction

Inbound bandwidth barely moved: **20.7 → 18.3 KB/s, a 12 % drop.** Removing 107.1 msg/s
whose bodies alone measured 10.3 KB/s should have taken inbound to near zero if the
earlier reading had been right. It took 2.4 KB/s — about 22 bytes per message removed,
against a measured mean body of 98 bytes. The numbers contradict each other, so the
"chat is essentially all of your download" claim does not survive its own test and has
been struck from the section above.

Two candidates, untested:

1. **`GetNetStats` had not settled.** It returns a rolling average, and the addon's own
   notes already warn it is "too coarse to pin one frame — read it ACROSS captures". A
   65 s window right after the change may still be carrying the old traffic. A re-read
   five minutes later settles this and costs nothing.
2. **~18 KB/s of inbound is something else entirely** and chat was only ever ~2 KB/s of
   it. In which case there is a second, larger consumer nobody has looked for, and the
   180 bytes/message arithmetic in the original analysis was a coincidence of numbers
   rather than a measurement.

Until one of those is checked, the honest statement is: **leaving the channels removed
107 chat events a second, and its effect on bandwidth is unmeasured.** The event
reduction stands on its own — it was always the larger cost.

`BBLC25C` is the largest single consumer and its owner was never identified — it is not
FrostSeek's. Leaving it is safe and reversible, so it does not need identifying first,
but if something stops working that channel is the first place to look.

## Pointing the finger without being asked (0.2.4)

Reading four fields and doing the arithmetic is work nobody should repeat every capture,
so the row now states its own conclusion as `v=`:

```
C^r=1^chan=BBLC25C^id=8^n=9335^ps=46.2^...^j=1^disp=0^v=COST
C^r=4^chan=Ascension^id=2^n=64^ps=0.3^...^j=1^disp=1^v=QUIET
```

- `COST` — at or over `Report.CHAT_BUSY_PS` **and** `disp=0`. Loud and invisible: you
  receive every message, every addon registered on `CHAT_MSG_CHANNEL` processes it, and
  nothing ever shows it to you. `/leave` it.
- `BUSY` — same volume but displayed. Your call; still named rather than hidden.
- `QUIET` — under the line.
- `?` — loud, but `GetChatWindowChannels` is unavailable so `COST` cannot be *claimed*.
  Same discipline as the spike classifier: no verdict the inputs do not support.

`CHAT_BUSY_PS = 5.0/s` is tuned from this capture, not guessed. The three machine
channels ran at 46.2/31.4/29.5/s; every channel humans talked in sat at 0.0–0.3/s and
totalled 0.44/s. The line clears the busiest human channel by ~15× and sits ~6× under
the quietest machine one, so it has wide margin in both directions. Re-tune from a
capture if a realm ever has genuinely busy chat — do not adjust it on a hunch.

The minimap notifier also raises a **watch** at `Storm.CHAT_FLOOD_PS = 20` msg/s, so a
flood surfaces without anyone asking for a report. It deliberately does *not* name the
channel: that needs `GetChannelList` + `GetChatWindowChannels`, which is report-path
work, not something to put on a ~1 s tick. The notifier says a flood exists and sends
you to `/cpp`; the `C` rows do the naming. It also does not blink — only a taint storm
blinks — and it ranks *below* the spike checks, because an acute stutter you are feeling
now outranks a chronic tax.

## Notes for anyone editing the instrument

- The counter hangs off a **dedicated narrow frame** registered only for
  `CHAT_MSG_CHANNEL`, not the `RegisterAllEvents` firehose — the same reasoning as the
  blocked-action counter. Capturing args up there would pay the arg cost on every CLEU.
- `j=` and `disp=` are both **tri-state** (`1` / `0` / absent when the API is missing).
  Neither may be written as `cond and X or nil`: with `X = false` that Lua idiom yields
  `nil` and collapses "definitely not" into "no opinion", which is the one verdict each
  field exists to deliver. A self-test pins all three states of both; it caught exactly
  that bug in `j=`'s first draft.
- `parseChannelList` is **stride-agnostic** — 3.3.5 is documented as `id, name` pairs and
  later clients add a third `disabled` value, so it pairs every number followed by a
  string. Both shapes are self-tested; guessing wrong would silently yield an empty
  joined list and no verdict at all.
- Joined channels match by **ID** (`GetChannelList`); displayed channels match by
  **name** (`GetChatWindowChannels` gives nothing else). If those ever diverge on this
  server a `j=0` would be a false positive — confirm with `/chatlist`.
- **Message text is never stored**, only channel, sender, count and byte total. The
  report is a blob pasted in public.

## What this cost, and what it was worth

The whole thing was one report row. The `R` rate row had been saying "chat is your
firehose" for two versions without anyone able to act on it, because the actionable part
— *which* channel, and *are you actually reading it* — was the part it did not carry.
