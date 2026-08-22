# Mounts and pets — the shipped Need rule, and how one is recognised

Added 2026-08 at the owner's request: *"certain chase items would be automatically greeded
when they should have need rolls, as this is the normal convention in pick-up groups"*.

## The problem

Out of the box PassLoot shipped two rules, both greed:

| # | Rule | Roll |
|---|---|---|
| 1 | Not Usable — the tooltip carries a red requirement line | Greed |
| 2 | Catch All — anything else | Greed |

A mount or a companion pet hits one of them and is auto-greeded. Which one it hits makes it
worse, not better: a mount you have not got the riding skill for **is** unusable by the red-line
test (`USABLE-SCAN.md`), so rule 1 claims it — the addon greeds the drop of the run *because*
you cannot ride it yet, which has nothing to do with whether you want it. In a pick-up group the
convention on a mount or a pet is Need, and the addon was quietly rolling the other way with
nobody watching.

## The shipped rule

`Core/Constants.lua` `PasslootBiS.MountPetRule`, first in `DefaultRules`:

```
Mounts & Pets      Mount / Pet = "Mount or Pet"
                   Learned Item = "Unlearned"        ->  Need (Greed where Need is not allowed)
                   Before Advisor: ticked
```

Four decisions in that, each of which is the answer to an obvious "why not just…":

- **First in the list.** Rules are evaluated top-down, first match wins. Below either greed rule
  it would never match.
- **`Loot = { "need", "greed" }`.** `RollOrder` (`Core/PassLoot.lua`) picks the highest-priority
  entry the roll actually *allows*. Need-only would leave the rule matching and rolling nothing
  on a roll where Need is disabled — worse than the greed it replaced.
- **Before Advisor ticked.** A mount has no equipped counterpart, so the roll advisor has nothing
  useful to say about one; but under `trust` or `held` a gold-value verdict could still convert
  or hold the roll, and a countdown popup over an uncontroversial mount Need is noise. BiS
  Check's downgrade veto still outranks this (`BIS-CHECK.md`) and that is fine — it only fires on
  an item scored against gear in the same slot.
- **`Learned Item = Unlearned`.** Needing on a mount you already own is the same breach of
  etiquette this rule exists to fix, pointed the other way. It fails toward Need: `LearnedItem`
  reads the tooltip's "Already known" line, and when it cannot tell it answers Unlearned.

**Existing installs get it too.** `SeedDefaultRules` only ever fires on a profile with no rules
at all, and only once, so a rule added after release reaches nobody who already plays with the
addon — which is the entire population this bug affects. `PasslootBiS:SeedMountPetRule`
(`Core/PassLoot.lua`) hands the one rule to an existing profile, once, guarded by its own
`MountPetRuleSeeded` flag and skipped for any profile that already has a rule using the filter.
Delete the rule and it stays deleted — see the next section for the way back.

## Getting a deleted starter rule back

Both seeds are one-shot by design, which is right for a rule you meant to be rid of and useless
for one you deleted by accident: nothing else in the addon could ever hand it back. Two answers,
added at the owner's request:

- **Turn a rule off instead of removing it.** The `Disabled` flag already existed — the minimap
  button's right-click menu sets it, and the roll loop skips such a rule whole — but the rules
  page painted a disabled rule exactly like a live one, so the feature was invisible where it
  mattered. A disabled rule now shows **greyed and marked `(off)`** in the list, and its own
  right-click menu carries the same on/off tick, right where the Remove button is. That is the
  reversible way to silence a rule.
- **`Restore Starter Rules`** (General options, beside Clean Rules; `RestoreDefaultRules` in
  `Core/PassLoot.lua`) puts back any starter rule the profile no longer has. It **only ever
  adds**: a starter rule you still have is left exactly as you have edited it, and your own rules
  are untouched. It reports in chat which rules it restored, or that none were missing — a button
  that looks inert is worse than one that asks first.

Two details worth knowing before changing it:

- **Rules are identified by `Desc`**, the same way a BiS list's rules are found. So a starter rule
  you *renamed* reads as missing and restoring adds a fresh copy beside it. The alternative —
  identifying a rule by the filter it uses — is worse: plenty of ordinary hand-made rules use a
  `Usable` or `CanIRoll` filter and would each suppress the restore of a rule that really is gone.
- **Position is not "append".** Each missing rule goes back *before the first later starter rule
  the profile still has*, or at the end if there is none. Order is the whole design of that set:
  `Catch All` matches everything, so anything restored below it would never be reached, and
  `Mounts & Pets` restored below `Not Usable` would never match either — which would make the
  button look like it had done nothing.

## Why a new module and not Type / SubType

`Modules/TypeSubType.lua` can already express "Miscellaneous - Mount", so the rule could in
principle have been built from it. It is not a safe basis for something we *ship*, because it
matches the subclass **by name** — it compares `GetItemInfo`'s localized subclass string against
LibBabble's `"Mount"` / `"Pet"`. Both items in the request argue against that:

| Item | id | class | subclass | quality | Use: line |
|---|---|---|---|---|---|
| Deathcharger's Reins | 13335 | 15 Miscellaneous | **5 "Mounts"** | 4 Epic | "Teaches you how to summon this mount. This is a Ground mount." |
| Sigil of Lethtendris | 60060 | 15 Miscellaneous | **2 "Companions"** | **6 "Vanity"** | "Teaches you how to summon this companion. This is a non-combat companion." |

(rows as `db.ascension.gg` serves them, `?item=<id>&xml`, 2026-08)

Neither subclass is the singular string `TypeSubType` looks for, and 60060 is quality 6 — a
quality that does not exist on a stock 3.3.5 client at all. Whatever the live client returns for
those two subclasses, a shipped default that hangs on one exact spelling is one DBC edit away
from silently doing nothing, and "silently does nothing" is indistinguishable from the bug being
fixed here.

## How `Modules/MountPet.lua` decides

Two independent signals, either of which is enough:

1. **The subclass**, lowercased and looked up in a set that holds both spellings the Ascension
   database uses *and* the client's own (`mount`/`mounts`, `pet`/`pets`/`companion`/`companions`
   /`companion pets`/`non-combat pet`), plus LibBabble's translation of "Mount" and "Pet" for a
   non-enUS client. Costs nothing — the string is already on the item object.
2. **The item's own `Use:` line**, for anything filed under a subclass that says nothing. This is
   what the *player* reads to decide it is a mount: `summon this mount`, `summon this companion`,
   `non-combat companion` and friends, matched as plain substrings on the cached tooltip.

The tooltip scan **stops at the first line beginning with a newline**, exactly as
`Modules/LearnedItem.lua` does and for the same reason: that break is where a recipe's tooltip
starts describing the item it creates. Without it `Schematic: Mekgineer's Chopper` reads as a
mount and Needs itself — the recipe is a trade good, and the convention this rule ships for is
about the mount, not the pattern that makes one.

The module answers **only** "is this a mount or a pet?". Ownership is `LearnedItem`'s question
and the shipped rule combines the two, rather than either module growing a second job.

## Checking it

- Offline: `lua5.1 management/addons/passlootbis/tools/mountpet-smoke.lua` — 14 assertions over
  both routes, including the two items above and the recipe case.
- In game: `/plbisdebug item ` then shift-click a mount or pet. The report's item section prints

  ```
    mount/pet: yes   (2 Mount, by subclass)   subclass: Mounts
  ```

  routed through the module the rule itself uses, so it is the answer a live roll would get.
  **`by tooltip` is the interesting one**: it means the subclass did not say, and the fallback
  carried it. **`mount/pet: no` on something you can plainly summon is the finding** — copy the
  `subclass:` field, which is the string that needs adding to the set.

## Not verified in the client

The whole feature is reasoned and checked offline; nothing here has seen a live loot roll. The
one input that cannot be read from this repo is the subclass string the live client returns for
item classes 15/5 and 15/2 — hence two signals and a debug line naming which one fired, rather
than a guess dressed as a fact.

The same goes for the two UI additions above: `RestoreDefaultRules`' ordering is pinned by
reasoning and a throwaway run over the real function (every case: each rule missing on its own,
all three missing, user rules interleaved, a second press adding nothing, the selection following
its rule across the insert), but the button, the greyed line and the right-click tick have only
been read, not clicked. `TESTING.md` §I steps 32–33 are the click-through.
