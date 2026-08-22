# The Ironforge chat flood — solved

**Status:** solved in game, 2026-08. Three addon data channels account for **99.6 %** of
it. The addon whose channels they are was already disabled and it changed nothing,
because **unticking a channel does not leave it**. That is the finding worth keeping.

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

Payload is about half the wire cost: 10.3 KB/s of message bodies against
`in=20.7 KB/s` measured, i.e. ~99 bytes of per-message protocol overhead (sender GUID,
channel name, flags) on top of each body. So the chat traffic really is essentially the
entire inbound stream, with the overhead accounted for rather than hand-waved.

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

`BBLC25C` is the largest single consumer and its owner was never identified — it is not
FrostSeek's. Leaving it is safe and reversible, so it does not need identifying first,
but if something stops working that channel is the first place to look.

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
