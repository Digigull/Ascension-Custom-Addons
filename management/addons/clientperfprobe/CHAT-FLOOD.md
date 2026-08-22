# The Ironforge chat flood — solved

**Status:** solved in game, 2026-08, and the fix is measured. Three addon data channels
were **99.6 %** of it; leaving them took `CHAT_MSG_CHANNEL` from **107.6/s to 0.5/s**.
The addon whose channels they are was already disabled and it changed nothing, because
**unticking a channel does not leave it** — that is the finding worth keeping.

Bandwidth: **20.7 → 12.5 KB/s, 40 % of inbound removed.** That figure took three captures
to establish because `GetNetStats` is a rolling average and had not settled; the two
intermediate conclusions drawn from it were both wrong and are kept below rather than
quietly deleted, because the settling trap is the reusable lesson.

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

`FSK` and `FSK-EVT` are FrostSeek's (`github.com/ayro-CMD/FrostSeek`), confirmed in its
source — `CHANNEL = "FSK"` in `Modules/Network/Network.lua` and
`EVENT_CHANNEL = "FSK-EVT"` in `Modules/Community/Community.lua`, over a "serverless
FrostNet protocol with heartbeat keepalives", which is what a 29-byte message is. All three carry
many distinct senders — `snd=48` on two of them, and `cap=1` says the probe's
distinct-sender cap was hit, so 48 is a floor and `top=` is only the loudest of the first
48 it tracked. Many senders each contributing a little is **peer-to-peer addon sync**:
every player running the addon broadcasts to the channel and every other player receives
it. Not one spammer, not a server broadcast.

Message bodies came to 10.3 KB/s against `in=20.7 KB/s` measured. The inference drawn
from that at the time — that chat was essentially the *entire* inbound stream — was too
strong: it measured out at **40 %**. See "And what it did to bandwidth" below, which also
covers the two wrong readings taken on the way there.

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

### And what it did to bandwidth — after two wrong readings

This took three captures to get right, and both intermediate conclusions were wrong.

| | `in=` | chat | |
| --- | --- | --- | --- |
| before `/leave` | 20.7 KB/s | 107.6/s | |
| 65 s after | 18.3 KB/s | 0.5/s | *"barely moved - so chat was never the bandwidth"* |
| 11 min after | **12.5 KB/s** | 0.7/s | still falling |

**`GetNetStats` was simply still settling.** It returns a rolling average, and the
addon's own notes already warned it is "too coarse to pin one frame — read it ACROSS
captures". The 65 s reading was taken before the average caught up, and the correction
written from it — that chat was never the bandwidth and some larger consumer must be
hiding — was premature. There is no hidden second consumer.

Settled figures: **20.7 → 12.5 KB/s, 8.2 KB/s removed, 40 % of inbound.** The remaining
~12.5 KB/s standing in a capital city is ordinary world state.

The original claim was still too strong, though. Chat was **40 % of inbound, not
essentially all of it**, and the 180 bytes/message arithmetic that suggested otherwise
was a coincidence. Note also that message *text* measured 10.3 KB/s while inbound fell
only 8.2 — text exceeding the wire drop is expected rather than contradictory: `kbps=`
is the length of the Lua message string, decompressed, and 3.3.5 compresses traffic that
repetitive addon payloads compress very well. `kbps=` is a relative weight between
channels, not a bandwidth figure, and the glossary now says so.

**The lesson, which is the reusable part:** a rolling-average API needs a settling period
before an A/B means anything. Two captures 11 minutes apart disagreed by 32 % with
nothing changing in between. Wait five minutes, or read the trend across three captures —
never conclude from the one taken straight after the change.

### What `BBLC25C` is

Checked against FrostSeek's source rather than guessed. It appears there three times —
in `Modules/LFG/LFG.lua`'s `CHANNEL_BLACKLIST` and twice in `Modules/LFG/LFM.lua` — and
every one is a **blacklist**: channels FrostSeek recognises as *other addons'* data
channels and excludes from its LFG/LFM scanning. FrostSeek never joins it. Its own
channels are only two, `FSK` (`Modules/Network/Network.lua`) and `FSK-EVT`
(`Modules/Community/Community.lua`), which matches the README and the 29–31 byte
heartbeats measured.

So `BBLC25C` belongs to a **third-party LFG addon in the same ecosystem**. FrostSeek's
blacklists name its peers: `BLFG`, `HGE`, `BBLC25C`, plus a generic
`^[A-Z][A-Z]%d+[~:]` protocol-prefix matcher and an explicit `^LC[123]` one — and
`BBLC25C` contains that `LC`. The owning addon is **not identified**: the name is not
documented anywhere publicly reachable, and no addon in this client's list claims it.

What *is* established, and it is the more useful half:

**Nothing on this client owned it.** The capture after leaving was taken following a
full addon-load cascade — all 21 addons loaded, `L` rows for every one — and `BBLC25C`
did not reappear in `GetChannelList`. Nothing re-joined it. The membership was a
leftover: joined once by an addon since removed or disabled, and persisted in the saved
chat config ever since.

That makes it the purest possible case of the pattern this whole document is about:
**46 messages a second, 188 bytes each, for an addon that was not even installed.** Not
a busy channel, not a misbehaving addon — pure residue, invisible, and costing more than
the two channels whose addon the owner actually uses. It is exactly what `v=COST` exists
to catch, and it is why `j=1 disp=0` is worth a verdict of its own rather than two fields
a reader has to combine.

Leaving it was safe and reversible (`/join BBLC25C` restores it). If something ever does
stop working, that channel is the first place to look — but nothing on this client reads
it, so nothing should.

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
- **Channel IDs are not stable.** Leaving the three offenders renumbered every survivor
  (Ascension 2→1, Newcomers 3→2, Zone 4→3, Trade 5→4, LookingForGroup 6→5). `Chat:record`
  therefore keeps the *latest* id seen for a channel, not the first: a first-sight-only
  id goes stale the moment you `/leave` something mid-window and can then mis-match a
  freshly-read `GetChannelList`, flipping `j=`. Both sides being read at the same moment
  is what makes ID matching safe; persisting an ID across a capture is not. Self-tested.
- **Message text is never stored**, only channel, sender, count and byte total. The
  report is a blob pasted in public.

## What this cost, and what it was worth

The whole thing was one report row. The `R` rate row had been saying "chat is your
firehose" for two versions without anyone able to act on it, because the actionable part
— *which* channel, and *are you actually reading it* — was the part it did not carry.
