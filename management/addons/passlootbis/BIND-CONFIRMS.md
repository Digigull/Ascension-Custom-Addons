# The three bind-confirmation popups

Field-tested 2026-08. Recorded because the root cause below is genuinely
counter-intuitive and cost a round of in-game testing to find: a feature that
*exists and works* can still never fire.

## Three popups, three events, three APIs

| When | Event | Confirm with | Answered by |
|---|---|---|---|
| The addon rolls Need/Greed on a BoP item | `CONFIRM_LOOT_ROLL` | `ConfirmLootRoll(id, type)` | `AutoConfirmBindOnRoll` (profile-wide, **on**) + the per-rule `Confirm BoP` filter |
| The addon rolls Disenchant on a BoP item | `CONFIRM_DISENCHANT_ROLL` | `ConfirmLootRoll(id, type)` | the per-rule `Confirm DE` filter **only** — deliberately |
| You take a BoP item out of a loot window | `LOOT_BIND_CONFIRM` | `ConfirmLootSlot(slot)` | `AutoConfirmBindOnPickup` (profile-wide, **off**) |

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
- **Pickup confirms default OFF.** Confirming binds an item permanently, on an
  action the addon did not initiate.
- **One shared once-guard**, `PasslootBiS:ConfirmRollOnce`. The profile-wide setting
  and the per-rule filter both answer the same event, so on a ticked rule both fire
  for one roll; the second becomes a no-op. It also owns the popup-hide, done twice
  (immediately and next tick) because the client's own `GroupLootFrame` listens for
  the same event and the dispatch order between its handler and ours is undefined.

## Debugging this in game

`/plbisdebug` toggles the `Debug()` trace (there was previously no way to turn it on
short of editing `Core/Constants.lua`). With it on, the roll path logs rule matches,
each `RollOnLoot`, and every confirm — including `not our roll, leaving the popup`,
which is the line that tells you a prompt you had to click by hand was a manual roll
rather than a missed auto-confirm.

## Not verified in game

The roll-confirm scoping and the `/plbisdebug` toggle are reasoned and
syntax-checked only. The pickup path is likewise still unconfirmed — no BoP pickup
prompt has been observed answered yet.
