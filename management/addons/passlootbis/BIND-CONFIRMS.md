# The three bind-confirmation popups

Field-tested 2026-08. Recorded because the root cause below is genuinely
counter-intuitive and cost a round of in-game testing to find: a feature that
*exists and works* can still never fire.

## Three popups, three events, three APIs

| When | Event | Confirm with | Answered by |
|---|---|---|---|
| **Anyone** rolls Need/Greed on a BoP item — the addon or you, by hand | `CONFIRM_LOOT_ROLL` | `ConfirmLootRoll(id, type)` | `AutoConfirmBinds` (profile-wide, **on**) + the per-rule `Confirm BoP` filter |
| The addon rolls Disenchant on a BoP item | `CONFIRM_DISENCHANT_ROLL` | `ConfirmLootRoll(id, type)` | the per-rule `Confirm DE` filter **only** — deliberately |
| You take a BoP item out of a loot window | `LOOT_BIND_CONFIRM` | `ConfirmLootSlot(slot)` | `AutoConfirmBinds` — the same setting |

All three are answered from the **event**, never by clicking the popup frame. That
matters: the client caps how many static popups can be on screen, and
`CONFIRM_LOOT_ROLL` carries the `exclusive` bit by default so only one shows at a
time — but the *event* fires for every roll regardless. Event-driven confirmation is
therefore immune to the popup queue entirely, which is why no throttle is needed.

## The root cause worth remembering

`Modules/ConfirmBoP.lua` has answered `CONFIRM_LOOT_ROLL` since the fork, and the
code is correct. It just never ran, because it gates on the matched rule having the
`Confirm BoP` filter ticked:

```lua
local Value = self.Widget:GetData(RuleNum)   -- nil for any rule without the filter
if (Value and BoP and ...) then self.ItemsAwaitingConfirmation[RollID] = ... end
```

**No rule a normal setup actually rolls with has that tick.** The two seeded starter
rules (`Core/Constants.lua` `DefaultRules` — "Not Usable > Greed", "Catch All >
Greed") carry only their match condition, and BiS-imported rules carry only their
ID/name lists. So on live boss loot the rule matched, the roll was cast, and the
confirm sat there unanswered.

It presents as *"epic items don't auto-roll"* — because boss epics are BoP and BoP
is what raises the prompt — and as a multi-drop problem, because the exclusive bit
shows the queued popups one at a time. Neither is the actual variable. **BoP is.**

The lesson generalises: a per-rule opt-in that no shipped or generated rule sets is
indistinguishable from a feature that does not exist.

## Decisions

- **Roll confirms are profile-wide and default ON.** Your rules already decided to
  roll; the client is only asking you to reconfirm that decision. Off means
  auto-rolling silently does not work on most boss loot.
- **~~Scoped to rolls the addon cast~~ (`PasslootBiS.CastRolls`) — superseded
  2026-08.** The original argument: `CONFIRM_LOOT_ROLL` fires for a Need you clicked
  by hand too, and answering that one removes a prompt the client puts on a
  deliberate action. What killed it was a full dungeon run — the owner still had to
  click Okay on greed prompts several times, and the trace was three `not our roll,
  leaving the popup` lines with no auto-confirm anywhere. The pickup prompt's own
  supersession applies here verbatim: the box only appears because you chose that
  roll, so "yes" is the answer in every case that has come up, and a switch that
  reads "answer bind prompts for me" while answering only the addon's half is the
  same half-working setting the three-box merge below exists to avoid. **Every
  Need/Greed bind prompt is answered now.** Disenchant is still excluded.
- **`CastRolls` is kept as a trace ledger, not a gate.** The auto-confirm line now
  names the origin — `addon-cast`, `hand-cast`, `addon-cast, link changed` (the
  rollID was recycled between cast and prompt), or `addon-cast, roll no longer live`
  (the roll went away underneath us). It stores the item LINK rather than `true`
  because rollIDs are recycled within a session, so a mark left by a cast that drew
  no confirm (any non-BoP roll) would otherwise make the next roll to reuse that id
  look like ours. Nothing acts on the distinction any more; it is there because it
  is the first thing a "why did it roll that?" report has to answer, and because it
  is what would settle a future *missing* auto-confirm.
- **Disenchant is never folded in.** Rolling DE on someone else's upgrade is the one
  roll here that can genuinely annoy a group, which is why `Modules/ConfirmDE.lua`
  makes you confirm the *filter* before it will auto-confirm the *roll*. That opt-in
  stands.
- **One setting, not three.** Roll confirms, pickup confirms and the popup-queue
  bit shipped as three separate boxes (`AutoConfirmBindOnRoll`,
  `AutoConfirmBindOnPickup`, `AllowMultipleConfirmPopups`). Owner's call after the
  first in-game round: fold them into one, **`AutoConfirmBinds`**, default on.
  They are three halves of one behaviour — "does PassLoot answer bind prompts for
  me" — and three boxes only meant three ways to have it half-work.
  - The pickup box previously defaulted **off**, on the argument that confirming
    binds an item permanently on an action the addon did not initiate. Superseded:
    the prompt only appears because you chose to take that item, so "yes" is the
    answer in every case that has come up. **Consequence to know: turning the one
    setting on does mean BoP pickups stop asking.**
  - The queue bit is not an independent decision either. It only changes what
    happens to prompts this setting is already answering, so it follows it:
    auto-confirm on clears `exclusive` (the one prompt we deliberately do *not*
    answer — a disenchant — shows straight away instead of queueing behind a popup
    that is about to be hidden, and, now that hand-cast rolls are answered too,
    several BoP drops at once are all answered in one breath rather than one popup
    per click); auto-confirm off puts the client's own behaviour back.
  - `PasslootBiS:MigrateBindConfirmOptions` folds an existing profile in, at load
    and on every profile switch. The old *roll* box decides the new value (it was
    the one that was on by default and the one that makes auto-rolling work at all),
    then all three old keys are cleared. **The trigger is the old key being present,
    not the new one being absent** — AceDB `copyDefaults` rawsets scalar defaults
    into the profile table, so `AutoConfirmBinds` is physically there and `true` on a
    profile that has never seen it, and "is it missing" can never answer yes. It
    works out exactly right anyway: `removeDefaults` strips values equal to the
    default on save, so only a user who turned the roll box *off* has a stored key,
    and everyone else lands on the new default of on — the same answer.
- **One shared once-guard**, `PasslootBiS:ConfirmRollOnce`. The profile-wide setting
  and the per-rule filter both answer the same event, so on a ticked rule both fire
  for one roll; the second becomes a no-op. It also owns the popup-hide, done twice
  (immediately and next tick) because the client's own `GroupLootFrame` listens for
  the same event and the dispatch order between its handler and ours is undefined.

## Debugging this in game

`/plbisdebug` — see the "Diagnostics" section of `BIS-CHECK.md`. The line that
settles a confirm question is `CONFIRM_LOOT_ROLL: auto-confirming roll N (origin)`.
If a prompt still needed a click, ask of the trace, in order:

1. **No `CONFIRM_LOOT_ROLL` line at all** — the event never reached us. Check the
   setting, then the registration; the rest of this file is beside the point.
2. **The line is there and a popup still sat on screen** — the confirm landed and
   the *hide* failed, not the other way round.
3. **The origin word.** `hand-cast` is now a normal, answered case. `addon-cast,
   link changed` or `addon-cast, roll no longer live` mean the ledger and the client
   disagree about this rollID, which is worth reporting even though nothing gates
   on it any more.

`not our roll, leaving the popup` no longer exists. A trace still carrying it is
from a build before this change.

## Verification status

First in-game round (2026-08, owner): the addons load clean, `/plbisdebug` reports,
and `[Contract self-test]` is all `PASS`. **Neither confirm path has been observed
firing yet** — the boss-drop run (roll confirm) and the corpse-loot run (pickup
confirm) are still outstanding, and until one of them produces
`CONFIRM_LOOT_ROLL: auto-confirming roll N` or `LOOT_BIND_CONFIRM: auto-confirming
loot slot N` in the trace, the root cause above is a diagnosis and not a result.

Second in-game round (2026-08, owner, full dungeon run): still no auto-confirm line.
The trace holds three greed rolls the addon cast and three `CONFIRM_LOOT_ROLL n: not
our roll, leaving the popup` lines (ids 4, 9, 8), and the owner had to click Okay by
hand a few times.

**Owner's testimony, asked directly: they did not click Need or Greed on any of
them.** That is the load-bearing fact, because nothing else raises this popup —
`CONFIRM_LOOT_ROLL` fires only in response to a `RollOnLoot` call, so those rolls
were ours and the `CastRolls` identity check refused our own casts. **This is
therefore a live bug and not merely a scoping decision** — the widening removes the
symptom, but something is wrong underneath and the ledger is the place to look.

Two things about reading that report, both of which caught me out once:

- **The 41 captured lines were the whole window, not a tail.** The ring holds 400
  (`MAX_LINES`) and `DebugVar` starts **off** at every login (`Core/Constants.lua`),
  so a report showing well under 400 lines is everything since `/plbisdebug on`.
  Inside that window: three addon greed rolls, three refused prompts, zero
  auto-confirms. The owner's impression that *some* items confirmed themselves
  earlier in the run is not contradicted by the trace — it is simply not covered by
  it, because tracing was not on yet.
- **A module's `Debug` never reaches the ring.** `PasslootBiS.Prototypes:Debug`
  (`Core/ModulesGUI.lua`) `Pour`s to chat instead of calling `DebugCapture`. So the
  absence of `ConfirmBoP CONFIRM_LOOT_ROLL` lines in `[Trace]` says nothing about
  whether that module ran.

The leading hypothesis for the refusal is that `GetLootRollItemLink(RollID)` does not
answer during `CONFIRM_LOOT_ROLL` on this client — the ledger stores a link at cast
time and compares it at confirm time, and a nil there fails the compare for every
BoP roll we make. The client's own `GroupLootFrame` handler uses
`GetLootRollItemInfo` at that moment, not the link, so FrameXML is no evidence
either way. The new origin word settles it: **`addon-cast, roll no longer live`
confirms this hypothesis, `addon-cast, link changed` points at rollID recycling
instead, and a plain `hand-cast` would mean the ledger entry was never written and
the fault is on the cast side.**

The single-setting merge and the widening are both reasoned and syntax-checked only.
