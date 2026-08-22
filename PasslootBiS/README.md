# PassLoot (BiS)

A fork of PassLoot that adds BisBeard BiS-list import, an Ascension-aware rule
set, and a roll-advisor API other addons can plug into.

**Version 1.0 · Interface 30300 (WotLK 3.3.5 / Ascension)**
Original by Odlaw, modified for Ascension by Xan; this is the BiS-import fork.

> **Runs standalone — do not enable it alongside stock PassLoot.** Both register
> the same rule engine and will fight over the roll frame.

## What it does

PassLoot auto-rolls Need / Greed / Disenchant / Pass on loot rolls according to
rules you define. This fork keeps that intact and adds:

### BiS list import

Paste a `PLBIS1:` string (produced by the BisBeard → PassLoot converter) into the
**Import BiS** options page and it builds rules for you. Items are split into two
rules — one matched by item ID, one by exact name — which you can then edit in
the Rules list like any other rule. Plain and compressed (`PLBIS1Z:`) strings are
both accepted.

A new list's rules land in the **Before Advisor** section at the top of the rule
list, so your BiS picks are matched before any catch-all rule and before the roll
advisor gets a say. Move them with Up/Down or untick the box if you would rather
they didn't. Re-importing a list you already have, or re-applying a tick selection
from the BiS Manager, rebuilds those rules where they stand and leaves both
choices alone.

Matching is deliberately restricted to item ID and exact name. It never emits
ilvl, quality or stat filters, because link-derived stats are unreliable on this
client for scaled instances.

### Ascension-specific rule modules

On top of the stock modules (item level, quality, equip slot, bind type, zone,
class, usable, …) this fork adds:

- **Mount / Pet** — match mounts and companion pets, whatever subclass the server
  filed them under (it falls back to the item's own "summon this mount" Use: line)
- **Mystic Enchant** — match only unlearned mystic enchants
- **Vanity Unlock** — match only unlearned vanity items
- **Wardrobe Unlock** — match only unlearned wardrobe appearances
- **Mythic Plus Level** — match on Mythic difficulty tier
- **Item Price** — match against vendor value

### Starter rules

A profile with no rules of its own is given three, tried top-down:

| # | Rule | Roll |
|---|---|---|
| 1 | **Mounts & Pets** — a mount or companion pet you have not collected | **Need** (Greed where Need is not allowed) |
| 2 | **Not Usable** — the tooltip carries a red requirement line | Greed |
| 3 | **Catch All** — anything else | Greed |

Rule 1 exists because the other two auto-greed a chase item, and a mount you have not
got the riding skill for is *unusable*, so it was rule 2 that claimed it — the addon
greeded the drop of the run because you could not ride it yet. Need is the pick-up
group convention, so that is the default. It is an ordinary rule: edit it, or delete
it and it stays deleted. Installs that predate it are given it once.

### Roll advisor API

A versioned `PasslootBiS.API` facade lets a companion addon register a roll
advisor. PassLoot stays the *sole* roller — an advisor only suggests a verdict,
it never rolls itself. Each advisor has a trust mode:

- `advisory` — the suggestion is shown, the rules still decide
- `held` — an actionable verdict shows a floating countdown popup for half the
  roll window and holds the auto-roll; you click Need/Greed/Pass, or the timer
  expires and the rule-computed roll goes through
- `trust` — the advisor's verdict is taken

Any single rule can opt out of all of that with the **Before Advisor** checkbox at
the right of its line in the rule list: when a rule ticked there matches and has a
roll to cast, that roll goes out immediately and no advisor is consulted.

The rule list shows this as two sections, which is also the order rules are tried
in — top to bottom, first match wins:

| Section | Numbered | What it is |
|---|---|---|
| **Before Advisor** | `01)` `02)` | Tried first, and rolled without asking the advisor |
| **After Advisor** | `1)` `2)` | Everything else — the advisor gets its say on these |

Each section is ordered on its own: Up and Down move a rule within its section, and
the Before Advisor checkbox is what carries it across the divider. Ticking it lifts
the rule to the bottom of the upper section; unticking drops it to the top of the
lower one, so it keeps the neighbours it had.

[PassLootBiS Scanner](../PassLootBiS_Scanner) is the reference consumer.

### Loot window and minimap button

A self-contained minimap button (no LibDBIcon — modern versions need APIs this
client doesn't have). Left-click opens a menu for the Loot Window, the BiS
Manager window, or the addon's settings; the existing LibDataBroker launcher is
untouched so Titan and friends still work.

The **Loot Window** renders a passive log of who rolled what and who won, built
by parsing the group loot-roll chat. Patterns are constructed from the client's
own global strings at runtime rather than hardcoded English.

### First-see roll fix

On 3.3.5 `GetItemInfo` returns nil the first time you encounter an item in a
session, which made PassLoot silently skip rule evaluation entirely — no
auto-roll on *any* rule, including ID-matched BiS rules. There is no
`ITEM_INFO_RECEIVED` event on this client, so the fix is a bounded re-poll over
about a second, plus recovering the exact item name from the link itself so
name-matched rules never depend on `GetItemInfo` at all.

## Installing

Copy the `PasslootBiS` folder into `Interface\AddOns`, keeping the folder name.
Ace3, LibBabble-Inventory-3.0 and LibSink-2.0 are bundled; nothing else is
required. Disable stock PassLoot first.

## Commands

| Command | Effect |
| --- | --- |
| `/passlootbis` | Open the settings (also via Interface → AddOns → PassLoot (BiS)) |
| `/plbisadvisor <name> <advisory\|held\|trust>` | Set an advisor's trust mode |
| `/plbisadvisor on\|off` | Master switch for the advisor system |
| `/plbismgr perf` | Opt-in perf probe for the BiS Manager window; `/plbismgr` reads the summary, `/plbismgr off` stops |
| `/plbisroll` | Passive roll-log tools: `summary` / `list` / `tips` / `sim <itemlink>` / `clear` |
| `/plbisloot` | Loot-tracker diagnostics: `on` / `off` / `globals` / `dump` / `clear` |

## Saved variables

- `PasslootBiSDB` — rules, settings, imported BiS lists, loot log
- `PassLootBiSRollLogDB` — the passive roll-log corpus

## Notes

StaticPopups and overlays don't render reliably on this client (they end up
behind the Interface Options window), so every window this fork adds is a plain
gameplay-time frame instead. The pure logic modules — import parsing, roll-advisor
verdict/hold decisions, retry gating, loot-log parsing — are written to load and
self-test under bare Lua 5.1 with no WoW API present.
