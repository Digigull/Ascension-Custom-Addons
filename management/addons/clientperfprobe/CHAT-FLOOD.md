# The Ironforge chat flood — 109 channel messages a second

**Status:** not solved. This documents what the capture proves, what it only suggests,
and the instrument added in 0.2.2 to name the culprit outright. Nothing here is
confirmed in game.

This came out of the sampler investigation (`SAMPLER-COST.md`) as a *separate* finding.
It is not what caused the 5-second spike grid, and the two should not be conflated.

## What the capture shows

From the same Ironforge capture (window 130 s, standing still, all of this repo's
addons disabled):

```
R^ev=CHAT_MSG_CHANNEL^n=14231^ps=109.3
R^ev=COMBAT_LOG_EVENT_UNFILTERED^n=1235^ps=9.5
R^ev=COMMENTATOR_SKIRMISH_QUEUE_REQUEST^n=219^ps=1.7
...
M^api=GetNetStats^st=ok^d=n=3 in=19.288648605347 out=0.10294754058123 lat=122.25
```

**14,231 channel messages in 130 seconds — 109.5 a second.** Every other event in the
client put together is an order of magnitude quieter.

## What that proves

- **It is machine traffic, not people.** A busy Trade chat on a large realm runs
  perhaps 1–3 messages a second. This is 35–100× that, sustained.
- **It is essentially your entire download.** 19.2 KB/s inbound ÷ 109.5 msg/s ≈ **180
  bytes per message**, which is the right order for a channel message with its sender
  and channel overhead. So the chat traffic and the inbound bandwidth are the same
  thing; there is no second mystery consumer hiding behind it.
- **It is not roster churn.** `CHAT_MSG_CHANNEL_JOIN` / `_LEAVE` do not appear in the
  top 15 events, so they are below 28 occurrences in the window. People are not cycling
  in and out of a channel; messages are genuinely being sent.
- **Whatever it is, it is not using the proper mechanism.** `CHAT_MSG_ADDON` — what
  `SendAddonMessage` produces, the sanctioned way for addons to exchange data — sat at
  **32 events, 0.2/s**. If this is addon data, it is being pushed through an ordinary
  chat channel instead, which is a common private-server workaround because
  `SendAddonMessage` is often throttled or restricted to party/guild/raid.
- **The connection is fine.** Latency was flat at 122–128 ms with outbound at 0.1 KB/s
  the whole time. This is volume, not lag.

## The one question that decides it

An addon cannot make `CHAT_MSG_CHANNEL` fire for traffic you would not otherwise
receive — **unless it joined a channel on your behalf.** So the whole diagnosis reduces
to: *which channel, and did you join it?*

- Top row is `Trade - City` or `General - <zone>` → genuine spam, no addon at fault.
  The cost is still real, but the fix is leaving the channel, not removing an addon.
- Top row is a name you do not recognise → something joined a data channel for you,
  and that addon is the answer.

## What was NOT established

**A named culprit.** The strongest correlate in the capture is `FrostSeek`:

```
O^r=10^addon=FrostSeek^mem=-5872.8
L^r=8^addon=FrostSeek^ms=60.4^heap=4205
```

It moved 5.8 MB in a single sample window — over 150× the next entry on the list
(`MoveAnything` at −35.2 KB). An addon cycling megabytes while you stand still in a city
is doing heavy string and table work, and parsing ~14,000 messages looks exactly like
that. But read the caveats before acting on it:

- The `O` value is a **delta since the previous sample**, and a negative number is a GC
  reclaim of memory already attributed to that addon — evidence of churn, not proof of
  what was being churned.
- Per-addon memory attribution on 3.3.5 credits whichever addon's code allocated. It is
  approximate and it is the only attribution channel this client leaves us
  (`scriptProfile` is locked — see the addon README).
- **Reading chat is not the same as causing it.** An addon that parses every channel
  message shows up as the heaviest consumer without being the thing that joined the
  channel. The consumer and the cause can be two different addons.

So: a lead worth checking first, not a verdict.

## The instrument (0.2.2)

New `C` rows in the report, one per channel, ranked by traffic:

```
C^r=1^chan=worldchannel^id=5^n=13980^ps=107.5^kbps=18.4^snd=1^top=Broadcast^topn=13980^j=1
C^r=2^chan=Trade - City^id=2^n=239^ps=1.8^kbps=0.7^snd=41^top=Someone^topn=22^j=1
```

- `kbps=` is the summed message bytes as KB/s, so the event rate can be set directly
  against the inbound KB/s `GetNetStats` reports. That is what turns "109 events/sec"
  into "this is your whole download".
- `snd=` distinct senders, `top=`/`topn=` the loudest one. One sender with essentially
  all the messages is a broadcaster; hundreds of senders is a populated channel.
- `j=` is **tri-state**: `1` joined, `0` not joined, and the field is **absent** when
  `GetChannelList` is unavailable and the probe has no opinion. It must never be written
  as `cond and X or nil` in Lua — with `X = false` that idiom yields `nil` and collapses
  "definitely not joined" into "no opinion", which is the one verdict the row exists to
  deliver. There is a self-test pinning all three states.
- Joined channels with **no** traffic still get a row at `n=0`. A quiet data channel is
  exactly what is being hunted, and it can be silent in any single window.
- **Message text is never stored** — only channel, sender, count and byte total. The
  report is a blob pasted in public and must not carry other people's conversations.

Implementation notes worth knowing before editing it:

- The counter hangs off a **dedicated narrow frame** registered only for
  `CHAT_MSG_CHANNEL`, not the `RegisterAllEvents` firehose — the same reasoning as the
  blocked-action counter. Capturing args up there would pay the arg cost on every CLEU.
- `parseChannelList` is deliberately **stride-agnostic**. 3.3.5 is documented as
  returning `id, name` pairs and later clients add a third `disabled` value; rather than
  betting on which Ascension ships, it pairs every number followed by a string. Both
  shapes are self-tested, because guessing wrong would silently yield an empty joined
  list and no `j=` verdict at all.
- Joined channels are matched by **ID, not name**: `GetChannelList`'s naming need not
  match `arg9`'s. If those numberings ever diverge on this server a `j=0` would be a
  false positive, so treat `j=0` as a strong hint and confirm with `/chatlist`.

## What to do in game

1. **`/chatlist`** — costs nothing and needs none of the above. It prints the channels
   you are currently in. If there is a name you do not recognise, that is your answer
   already. (It prints to chat, which cannot be copy/pasted on this client, but the list
   is short enough to read.)
2. **`/cpp clear`, wait two minutes, `/cpp`** and read the `C` rows. That names the
   channel, its loudest sender, and what share of your bandwidth it is.
3. **`/leave <channel>`**, then `/cpp clear` and wait two minutes again. If
   `CHAT_MSG_CHANNEL` collapses in the `R` row, confirmed. This is the decisive A/B and
   it takes about five minutes.
4. Only then go looking for which addon joined it — disabling half at a time and
   re-running step 1 is faster than reading source.

If the answer turns out to be `Trade - City` with hundreds of distinct senders, there is
no addon to find and the honest outcome is "the realm's trade chat is very busy" — worth
writing down here as a closed question rather than leaving it open.
