# PassLootBiS Scanner

Live loot-roll upgrade scanner. When an item comes up for roll it scores it
against what you're wearing and tells you whether it's an upgrade.

**Version 0.1.0-alpha · Interface 30300 (WotLK 3.3.5 / Ascension)**

## What it does

On `START_LOOT_ROLL` — and only when scanning is toggled on — it:

1. Resolves the rolled item's link to the inventory slot(s) it would occupy.
2. Scores it with your spec's stat weights.
3. Scores what you have equipped in that slot, taking the worst of the pair (the
   one you'd actually replace).
4. Fires an alert if the roll beats it by at least your threshold, or if the slot
   is empty.
5. Optionally adds a high-gold-value flag read from the Auctionator fork.

The whole scan runs inside a `pcall`, so a scoring error can never interfere with
the actual roll.

The alert is a floating frame plus a coloured chat line — never a StaticPopup,
which doesn't render reliably on this client. An upgrade verdict and a high-value
flag can appear alone or together.

### Reading true stats

Ascension's link-derived `GetItemStats` / `GetItemInfo` values are cached-first
and **lie for scaled instances**. So stats are read through the bundled
`LibScaledStats-1.0`, which scans a rendered tooltip pointed at the real item
instance. It owns its own hidden tooltip (never `GameTooltip`), emits BisBeard's
34 weight keys rather than raw `ITEM_MOD_*` names, and builds its patterns at
runtime from the client's own format strings, so it isn't locale-locked.

### Spec weights

All class/spec weights ship baked into `Data/Weights.lua`, generated from the
converter's `weights.json`. The spec is **user-selected, not auto-detected**:
Ascension is classless and the CoA weights use BisBeard's own taxonomy, so
there's no clean talent-to-spec identity to read in-game.

### Other surfaces

- **Tooltip annotation** — hover any piece of gear to see its score, plus an
  up/down arrow versus the item it would replace.
- **Options window** — class/spec dropdowns and a control for every setting that
  also has a slash toggle. Reached from the minimap button or `/plbs options`.
- **Per-character filter** — turn off armour materials and weapon types your
  character doesn't care about, so a rogue isn't scored on Plate and Bows. An
  absent entry means included; only an explicit exclusion filters. Anything not
  material- or type-restricted (necks, rings, trinkets, cloaks, relics) is always
  scored.
- **Roll advisor** — the verdict shape is the cross-addon contract consumed by
  [PassLoot (BiS)](../PasslootBiS)'s `PasslootBiS.API`, so the scanner's opinion
  can hold or drive PassLoot's auto-roll.

## Installing

Copy the `PassLootBiS_Scanner` folder into `Interface\AddOns`. LibStub and
LibScaledStats-1.0 are bundled.

Optional but recommended: `PasslootBiS` (roll-advisor integration) and
`Auctionator-Finder-Ascension` (gold-value flag). Both are read through guarded
global checks — neither is required.

**Set your spec before first use**; nothing is scored until one is picked.

## Commands

`/plbisscan` (or `/plbs`)

| Command | Effect |
| --- | --- |
| `/plbs` or `/plbs status` | Current state: on/off, spec, threshold |
| `/plbs options` | Open the settings window |
| `/plbs filter` | Open the per-character armour/weapon picker |
| `/plbs on` / `off` / `toggle` | Enable or disable scanning |
| `/plbs threshold <n>` | Minimum percent delta to call something an upgrade (default 3) |
| `/plbs spec` | List every class and spec |
| `/plbs spec <Class> \| <Spec>` | Set your spec (the dropdowns are easier) |
| `/plbs chat` / `frame` / `sound` / `tooltip` | Toggle each output surface |
| `/plbs price <item>` | Probe the Auctionator fork's last-scanned price for one item |
| `/plbs debug` | Dump the raw stat lines the scorer sees into a copyable box |

## Saved variables

- `PassLootBiS_ScannerDB` — account-wide settings (threshold, output surfaces,
  gold threshold, minimap position)
- `PassLootBiS_ScannerCharDB` — per-character class/spec and gear filter

## Notes

- Alpha. The scoring cores (`Score`, `Slots`, `SpecWeights`, `Filter`, `Verdict`)
  are pure Lua and load/self-test under bare lua5.1 with no client present; every
  WoW-API touch is guarded.
- Scores match the converter's `score_item` exactly — a dot product over the
  intersection of the item's stats and the spec's weights. A stat with no weight,
  or a weight with no stat, contributes nothing.
- Soulbound gear never has auction data, so `/plbs price` on a BoP item correctly
  returns nothing. Smoke-test it against a BoE or a trade good.
