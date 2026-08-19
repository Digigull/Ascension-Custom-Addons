# The three bind-confirmation popups

Field-tested 2026-08. Recorded because the root cause below is genuinely
counter-intuitive and cost a round of in-game testing to find: a feature that
*exists and works* can still never fire.

## Three popups, three events, three APIs

| When | Event | Confirm with | Answered by |
|---|---|---|---|
| The addon rolls Need/Greed on a BoP item | `CONFIRM_LOOT_ROLL` | `ConfirmLootRoll(id, type)` | `AutoConfirmBinds` (profile-wide, **on**) + the per-rule `Confirm BoP` filter |
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
- **Scoped to rolls the addon cast** (`PasslootBiS.CastRolls`). `CONFIRM_LOOT_ROLL`
  fires for a Need you clicked by hand too, and answering that one removes a prompt
  the client puts on a deliberate action. `CastRolls` stores the item LINK rather
  than `true` — rollIDs are recycled within a session, so a mark left by a cast that
  drew no confirm (any non-BoP roll) would otherwise make the next roll to reuse
  that id look like ours.
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
    auto-confirm on clears `exclusive` (anything we deliberately do *not* answer —
    a hand-cast roll, a disenchant — shows straight away instead of queueing behind
    a popup that is about to be hidden); auto-confirm off puts the client's own
    behaviour back.
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
settles a confirm question is `not our roll, leaving the popup`: it means a prompt
you had to click by hand was a *manual* roll, not a missed auto-confirm.

## Verification status

First in-game round (2026-08, owner): the addons load clean, `/plbisdebug` reports,
and `[Contract self-test]` is all `PASS`. **Neither confirm path has been observed
firing yet** — the boss-drop run (roll confirm) and the corpse-loot run (pickup
confirm) are still outstanding, and until one of them produces
`CONFIRM_LOOT_ROLL: auto-confirming roll N` or `LOOT_BIND_CONFIRM: auto-confirming
loot slot N` in the trace, the root cause above is a diagnosis and not a result.

The single-setting merge itself is reasoned and syntax-checked only.
