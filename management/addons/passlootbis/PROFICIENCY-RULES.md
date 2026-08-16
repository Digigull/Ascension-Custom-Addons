# Proficiency-driven rule generation (PasslootBiS)

Feature: read what the current character can actually equip, and turn the **gaps** into
auto-roll rules, so you stop rolling on gear you can't use.

Files: `PasslootBiS/Modules/Proficiency.lua` (pure logic + client probes, offline
self-tested) and the "Proficiencies" options page in `PasslootBiS/Core/PassLoot.lua`.

---

## 1. Is the proficiency data readable at all?

**Not verified in-game.** Nothing in this repo can be run, and Ascension's client is
visibly non-stock (it carries `C_MysticEnchant`, `C_Appearance`, `C_VanityCollection`,
`C_Item`, `C_Hook` — see `PasslootBiS/Modules/`), so "3.3.5 has this API" is not proof
that Ascension kept it. Two independent probes are therefore implemented, both guarded,
and **which one answered is shown to the user** rather than hidden.

### Probe A — skill lines (`GetNumSkillLines` / `GetSkillLineInfo`)

On stock 3.3.5 the Skills window lists `Armor Proficiencies` (Cloth, Leather, Mail,
Plate Mail, Shield) and `Weapon Skills` (Axes, Two-Handed Axes, Bows, Crossbows,
Daggers, Fist Weapons, Guns, Maces, Two-Handed Maces, Polearms, Staves, Swords,
Two-Handed Swords, Thrown, Wands). Weapon skill *ranks* were only removed in 4.0.1, so
on a WotLK-era client the lines are still there.

**Gotcha that would silently break this:** a *collapsed* header hides its children from
`GetNumSkillLines` entirely. A character playing with "Weapon Skills" collapsed would
read as having **no** weapon proficiency — which, without the refusal guard in §3, would
generate "pass on every weapon". `ScanSkillLines` therefore expands all headers, reads,
then re-collapses exactly the headers that were collapsed (matched by *name*, because
indices shift as headers expand; re-collapsed *backwards*, because collapsing at index
`i` only removes entries after `i`).

Skill-line names are localized, and the skill name is not always the item subclass name
("Swords" → One-Handed Swords, "Plate Mail" → Plate, "Shield" → Shields). The enUS names
are hardcoded — the same assumption `PassLootBiS_Scanner/Core/Filter.lua` already makes
for subclass strings — with the client's own localized *spell* name accepted as an extra
alias, which covers the armor set one-for-one on a non-enUS client.

### Probe B — the proficiency passives

The classic proficiency spells (196 One-Handed Axes … 9116 Shield; full table in
`Proficiency.LIST`). `IsSpellKnown(spellID)` is used when the client has it; otherwise
the 3.3.5 idiom `GetSpellInfo(<name>)` — a *name* lookup resolves only for a spell the
player knows, while the *id* lookup resolves for anything in the client's data. The
name-lookup fallback is the weaker of the two (a same-named spell would fool it, and
"Cloth"/"Mail"/"Shield" are generic names), which is why the panel prints the method it
used.

### Verifying the probes offline

Both probes run against a fake client in `tools/proficiency-probe-test.lua` (no WoW
needed), including the collapsed-header trap and the restore afterwards:

```
lua5.1 management/addons/passlootbis/tools/proficiency-probe-test.lua
lua5.1 -e 'PROFICIENCY_SELFTEST=true' PasslootBiS/Modules/Proficiency.lua
```

That proves the *logic* is right given a client that behaves like stock 3.3.5. It cannot
prove Ascension behaves that way — that needs the in-game step below.

### Verifying on a live character

`/plbisprof` prints, per proficiency, whether each probe found it:

```
skill lines: true (skill lines)
spells:      true (IsSpellKnown(spellID))
  One-Handed Axes    KNOWN    skill=true spell=true
  Bows               missing  skill=false spell=false
  ...
```

That output is what settles the question for Ascension. Three outcomes:

* both probes agree → done, nothing to change;
* one probe is dead (`false (…)` on its line, or all-`false` results) → the other still
  carries the feature; drop the dead one only if it produces *wrong* answers, not merely
  no answers;
* **both** dead → detection refuses and no rules are written. The fallback not built
  here would be a reference-item tooltip probe (one known item per subclass, checked for
  the red "you cannot use" line the way `Core/Cache.lua` already does). It is heavier and
  depends on `GetItemInfo` being warm, so it is not worth writing until the cheap probes
  are proven dead.

---

## 2. What the generated rules look like

Two rules, mirroring the two-rule split `BiSImport` uses (a rule ANDs its modules
together, so one combined rule matches nothing useful):

| Desc | Modules written |
|---|---|
| `Proficiency: unusable armor` | `TypeSubType` = every armor subclass with no proficiency; `EquipSlot` = Back / Shirt / Tabard as **exceptions** |
| `Proficiency: unusable weapons` | `TypeSubType` = every weapon subclass with no proficiency |

Within one module's filter list the entries OR together and exception entries AND-NOT
(`PasslootBiS:EvaluateItem`). A list made up **entirely** of exceptions therefore reads
as "everything except these" — which is what the armor rule's `EquipSlot` list is for:
cloaks, shirts and tabards are item subclass **Cloth** but need no proficiency, so a
plate-only character must not auto-pass its own back piece. Same carve-out, same reason,
as `PassLootBiS_Scanner/Core/Filter.lua`.

Rules are appended at the **bottom** of the rule list (a catch-all rule above them still
wins) and are keyed by a fixed `Desc`, so regenerating replaces them in place — keeping
their position in the priority order and the user's per-rule Disabled toggle — instead of
stacking duplicates.

---

## 3. Safety invariants

A wrong rule here silently passes on loot the user wanted, so every refusal path reports
*why* in the panel rather than writing something plausible:

1. **Zero detected proficiencies in a family → no rule for that family.** A character who
   can equip no armor at all does not exist; that reading means the probe failed. This is
   the single most important guard — it is what turns a broken probe into "nothing
   happened" instead of "passed on everything".
2. **Only *missing* subclasses are ever written.** Anything the table doesn't list —
   Fishing Poles, Miscellaneous weapons, Librams / Idols / Totems / Sigils / Relics — is
   never emitted, so an unrecognised item type is left alone rather than passed on.
   Relics are deliberately excluded: they are class-flavoured rather than
   proficiency-gated, and Ascension's classless system makes "which relic can I use" a
   question this code can't answer.
3. **`Type / SubType` module off → nothing is generated** (the rule could not match), and
   **`Equip Slot` module off → the armor rule is refused**, because without it the cloak
   carve-out is impossible. Both are reported, not silently skipped.
4. The detection is **never stored** in the DB. It is re-read from the client, so a
   proficiency trained later can't leave a stale rule behind unnoticed. The scan is
   cached in memory only (the skill-line probe mutates the Skills window's expansion
   state, so it must not run on every options repaint); Rescan is an explicit button.

---

## 4. Why not just use the existing `Usable` filter?

The `Usable` module already matches "the tooltip shows red text". That is broader *and*
blunter: it also fires on "Requires Level 78" gear you'll be able to wear in two levels,
and on reputation/class requirements. Proficiency-derived `TypeSubType` rules are stable
(they don't change as you level), explicit (you can see and edit every subclass in the
Rules list), and only ever cover the thing the user asked about. The `Usable` filter
remains the right tool for anyone who wants the blunt version.

---

## 5. Not done / open

* No in-game verification of either probe — see §1. `/plbisprof` output from a live
  character is the missing piece.
* Ascension-specific proficiency APIs (if any exist under a `C_*` namespace) were not
  searched for, because there is no client here to enumerate globals from. If probe
  output shows both classic probes dead, dumping `_G` for `C_.*[Pp]rofic` is the next
  step.
* Ranged-weapon nuance is not modelled: Thrown/Bows/Guns/Crossbows are treated as
  ordinary weapon subclasses, which is correct for rolling but means a hunter-style
  character with no melee proficiency will pass on melee weapons it might still want as
  a stat stick. Editing the generated rule covers this.
