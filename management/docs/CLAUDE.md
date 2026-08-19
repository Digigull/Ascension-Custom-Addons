# Working in Ascension-Custom-Addons

WoW 3.3.5 (Interface 30300) addons for Project Ascension. Five independent addons in one
repo; each **addon** folder drops straight into `Interface\AddOns` under that exact name.

This file holds the repo-wide conventions. It is imported by the root `CLAUDE.md`, which
exists only so this file is picked up when a session starts at the repo root.

## Repo layout

The five addon folders stay at the repo root so a user can download one and drop it into
`Interface\AddOns` unchanged. Everything that is *not* shipped to the client lives under
`management/`, which is the one top-level folder that is not an addon:

```
management/
  docs/                          repo-wide docs (this file, DRAG-FREEZE.md)
  addons/<addon>/                per-addon docs — findings, decisions, dead ends
  addons/<addon>/tools/          per-addon maintenance tooling, not shipped
```

Keep it that way: nothing under `management/` may be required at runtime, and no new
non-addon folder belongs at the root.

**Anything true of only one addon belongs in `management/addons/<addon>/`, not in this file.**
This file is read at the start of every session in the repo, so it stays worth reading only if
it holds rules that apply everywhere. Deep findings, measurements and rejected approaches go in
a per-addon doc; link it from the table below in one line rather than summarising it here.

## Environment

- **There is no Lua toolchain by default.** Install one before editing Lua:
  `apt-get install -y lua5.1`. Use **5.1 specifically** — that is what the 3.3.5 client runs.
- **Syntax-check every Lua edit:** `luac5.1 -p <files>`. Cheap, and the only automated check
  available; there is no test suite.
- **Validate XML edits** with `python3 -c "import xml.etree.ElementTree as ET; ET.parse('f.xml')"`.
  Several addons build frames in XML, where a typo silently breaks the whole file in-game.
- **Three files fail `luac5.1` on a UTF-8 BOM and are fine as they are** — the client's loader
  tolerates BOMs: `PasslootBiS/Core/Cache.lua`, `Auctionator-Finder-Ascension/Locales/esES.lua`,
  `Auctionator-Finder-Ascension/Locales/deDE.lua`. Do not "fix" them; just expect the noise when
  checking the whole repo.
- Nothing here can be run or screenshotted — verification is parsing, reading, and the owner's
  in-game test. Say plainly when a change is only reasoned, not verified.

## The drag freeze — the one domain rule that matters

Full write-up: `management/docs/DRAG-FREEZE.md`. Read it before touching any frame's
strata, `SetToplevel`, or `Raise`. Short version:

- **Never call `SetToplevel(true)` on a new window.** A toplevel frame re-raises on every
  click/drag; each raise restacks its whole strata. On a populated strata (`HIGH`, `DIALOG`,
  or an unset/inherited one) that is a **0.6–2.6 s full-client freeze** on the first drag of
  each session. On a sparse strata it is still ~50 ms *per drag*.
- **`Raise()` is the same restack.** It is the right replacement for click-to-raise, but only
  in a show path and only on a **sparse** strata. Never add `Raise()` to a window on `HIGH`.
- **`Raise()` cannot cross strata** — it orders a frame among its own strata's siblings only.
- **Scrims/masks must never be toplevel**: raising a mask lifts it above the dialog it masks.
- The backdrop, children, and drag-wiring are **exonerated** — an empty frame still froze.
  Never attribute a freeze to a backdrop.

**No file in this repo calls `SetToplevel(true)` any more.** The two isolation reproducers that
deliberately kept the bug (`PassLootBiS_Scanner/Core/DragTest.lua`, and the frame-spawners in
`!ClientPerfProbe/BackdropTest.lua`) were retired once the cause was confirmed — the measurement
they produced is preserved in `DRAG-FREEZE.md`. A new `SetToplevel(true)` anywhere is a
regression, with no exceptions to check first.

## Strata conventions

Order, low → high:
`WORLD < BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP`

Once `SetToplevel` is gone nothing raises, so strata is a **layering** choice, not a
performance one. Current decisions:

| Use | Strata | Examples |
|---|---|---|
| Persistent window left open while playing | `LOW` | cpp meter |
| Window that must clear the action bars / unit frames | `MEDIUM` + frame level 100 | BiS Scanner options/filter, PassLootBiS Loot Window |
| Deliberately opened; copy/paste popups | `FULLSCREEN_DIALOG` | cpp export/detail/glossary, BiS Scanner debug box |
| Opened from *inside* the Interface Options panel | `FULLSCREEN_DIALOG` | PassLootBiS BiS Manager |
| Attached to a Blizzard panel | match that panel | Honor Tracker panel (`HIGH`) |

Rules behind the table:

- Custom UI should generally render **under** the default Blizzard panels — `LOW` is the
  house default for anything you leave open.
- **`LOW` does not clear the action bars or the unit frames.** Blizzard's bars and unit frames
  are on `LOW` too (and they are `toplevel`, so clicking one lifts it over your window), and bar
  addons such as Bartender default to `MEDIUM`. A window that must never be drawn through by a
  health bar or an action button needs `MEDIUM` **and** a frame level well above its neighbours
  — within one strata the higher level wins. Both addons that need this have a helper for it,
  so don't hand-roll the pair: `ns.UI.applyWindowChrome()` (`PassLootBiS_Scanner/Core/UI.lua`)
  and `PasslootBiS:ApplyWindowChrome()` (`PasslootBiS/Core/PassLoot.lua`), both `MEDIUM` + level
  100.
- **Nothing on `MEDIUM` or above may call `Raise()`.** The raise is the drag-freeze restack;
  it is only cheap on a sparse strata. Use a fixed high frame level for front-on-open instead.
- **Exception: notifications.** A toast exists to be noticed and usually fires while bags are
  open. `PassLootBiS_Scanner/Core/Alert.lua` deliberately stays high.
- **Exception: copy/paste boxes.** You open them to read and select text from.
- **A window opened from a button inside the Interface Options panel cannot be lowered** — it
  would open invisibly behind that panel, and `Raise()` cannot rescue it.
- **Auctionator follows Blizzard's auction house chrome.** It attaches to the AH window; leave
  its layering alone unless asked.

## Styling

The house look is the flat dark "Details-style" backdrop: `UI-Tooltip-Background` +
a 1px `WHITE8X8` border, `SetBackdropColor(0.05, 0.05, 0.07, 0.95)`,
`SetBackdropBorderColor(0.30, 0.30, 0.34, 1)`.

- **Use the existing helper, don't paste the recipe**: `ns.UI.applyDarkBackdrop()`
  (`PassLootBiS_Scanner/Core/UI.lua`) and `PasslootBiS:ApplyDarkBackdrop()`
  (`PasslootBiS/Core/PassLoot.lua`).
- **Never restyle frames embedded in the Blizzard Interface Options panel** (e.g.
  `PasslootBiS/Core/MainGUI.lua`). A dark box on stock parchment reads as a seam, not a theme.
  The same reasoning keeps Auctionator's inline AH panels stock.
- Styling is cosmetic and has **no** bearing on the freeze. Keep the two concerns separate in
  commit messages and comments.

## Per-addon notes

| Addon | Indentation | Notes |
|---|---|---|
| `!ClientPerfProbe` | 4 spaces | The measurement addon. `darkBackdrop()` in `UI.lua` is its house helper. |
| `AscensionHonorTracker` | 4 spaces | Small. Panel attaches to the character panel; strata matches it. |
| `Auctionator-Finder-Ascension` | tabs | Largest, heavily XML. Local style puts a space before call parens: `f:SetSize (400, 124)`. Match it. Vendor pricing: `management/addons/auctionator/VENDOR-PRICE-RESEARCH.md` — read before touching the price estimator or the shipped seed. |
| `PasslootBiS` | tabs | Ace3. Load order in `Core/Core.xml`; `PassLoot.lua` loads first, so shared helpers go there. |
| `PassLootBiS_Scanner` | tabs | Load order in the `.toc`; `Core/UI.lua` loads before its consumers. Files guard on `rawget(_G, "CreateFrame")` so they stay loadable under bare lua5.1 — **preserve that**, it is what makes helpers testable offline. |

The two PassLoot addons are a designed pair (Scanner advises, PassLoot rolls). Changes to
their shared interface usually need both.

## Conventions

- **Match the file you are editing**, not this repo's average — indentation differs per addon
  (table above) and even per file within `PasslootBiS`.
- These addons carry unusually heavy explanatory comments, especially around strata. That is
  deliberate: several correct-looking edits reintroduce the freeze. **When you change
  behaviour a comment describes, update the comment in the same edit** — a stale comment
  arguing for the old approach invites someone to revert the fix.
- Mark superseded reasoning as superseded rather than deleting it, where the original decision
  explains a non-obvious choice (see the §8.6 note in `PasslootBiS/Core/LootWindow.lua`).
