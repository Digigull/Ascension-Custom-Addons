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
- **Syntax-check every Lua edit:** `luac5.1 -p <files>`. Cheap, and the baseline check.
- **Validate XML edits** with `python3 -c "import xml.etree.ElementTree as ET; ET.parse('f.xml')"`.
  Several addons build frames in XML, where a typo silently breaks the whole file in-game.
- **Three files fail `luac5.1` on a UTF-8 BOM and are fine as they are** — the client's loader
  tolerates BOMs: `PasslootBiS/Core/Cache.lua`, `Auctionator-Finder-Ascension/Locales/esES.lua`,
  `Auctionator-Finder-Ascension/Locales/deDE.lua`. Do not "fix" them; just expect the noise when
  checking the whole repo.
- **There is no test suite, but there ARE offline tests — run the ones that cover what you
  touched.** They stub the client and run under bare `lua5.1` from the repo root, in about a
  second each:

  ```
  lua5.1 management/addons/passlootbis/tools/contract-check.lua    # 20 assertions
  lua5.1 management/addons/passlootbis/tools/usable-smoke.lua      # 14 assertions
  lua5.1 management/addons/passlootbis/tools/report-smoke.lua      # 3 passes, non-zero on a crash
  lua5.1 management/addons/auctionator/tools/sell-variant-smoke.lua # 27 assertions
  lua5.1 management/addons/auctionator/tools/analysis-feed-smoke.lua # 27 assertions
  ```

  All five pass as of 2026-08. Non-shipped tooling lives in `management/addons/<addon>/tools/`;
  anything new belongs there, not in an addon folder. Several source files are deliberately
  shaped to be testable this way — helpers kept global, `rawget(_G, "CreateFrame")` guards — so
  **do not break that shape** when editing them. That is a preservation rule, not an
  instruction to grow the tooling; see the next bullet.
- The client itself cannot be run or screenshotted here. Beyond the checks above, verification
  is parsing and reading. Say plainly when a change is only reasoned, not verified.
- **Ship the change; verify it later. Tooling is a fallback, not a frontline** (owner's standing
  preference, 2026-08). A reasoned change goes out as it is. **A fix that fails on first run is
  an accepted cost** — cheaper, in both wall-clock and context, than the apparatus that would
  have caught it. Concretely:
  - **Run an existing test when it covers what you touched.** A second of runtime is not what
    is being discouraged.
  - **Do not build new harnesses, stubs or client emulation by default**, and do not grow a
    mock toward covering more of the WoW API. Write a new test only when the behaviour genuinely
    cannot be reasoned about, or when something has already failed once and you need to pin it
    so it stays fixed.
  - **An in-game debug command is the last resort, not the first.** Add one only when no
    offline route can answer the question, and say at the call site why that is.
  - **When you do add one, its output MUST go into a copy/paste window — never chat.**
    `zc.msg_atr`, `print` and `DEFAULT_CHAT_FRAME:AddMessage` are all dead ends here: **chat text
    cannot be selected on this client**, so anything printed there can only come back as a
    screenshot, and a screenshot of forty numbers is not evidence anybody can work from. A
    diagnostic whose output cannot be pasted back has not been delivered.

    The window is the one in the strata table below: `FULLSCREEN_DIALOG`, a dark backdrop, a
    multi-line `EditBox` in a `UIPanelScrollFrameTemplate`, `SetAutoFocus(false)`, and on show
    `SetText` → `HighlightText()` → `SetCursorPosition(0)` → `SetFocus()`, so the text arrives
    already selected and **Ctrl+C** works immediately. Title the window with that instruction.
    Working implementation to copy: `PassLootBiS_Scanner/Core/Scanner.lua`'s `/plbisscan debug`
    box (`PLBiSScannerDebugBox`), and `Atr_An_ShowDebugBox` in
    `Auctionator-Finder-Ascension/AuctionatorAnalysis.lua`.

    This applies to every addon here and to one-off diagnostics as much as to permanent ones —
    a throwaway that prints to chat is exactly the case where the output was needed most.
  - Match verification effort to the size of the change. A fixed ritual per edit — dozens of
    checks for a small update — is the failure mode to avoid, in both directions.
- **Do not re-raise the owner's parked in-game checks.** Where a doc lists something as
  "not verified in game", that is a record, not a request. The owner has the addons running and
  has decided (2026-08) that they behave correctly; anything that misbehaves will be reported
  when it does. Mention such an item only if the change in front of you actually touches it —
  never as a standing caveat on unrelated work.

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
| Persistent window left open while playing | `LOW` + frame level 100 | cpp meter, PassLootBiS Loot Rolls window |
| Window you open, use and close | `MEDIUM` + frame level 100 | BiS Scanner options/filter, PassLootBiS BiS cleanup |
| Deliberately opened; copy/paste popups | `FULLSCREEN_DIALOG` | cpp export/detail/glossary, BiS Scanner debug box |
| Opened from *inside* the Interface Options panel | `FULLSCREEN_DIALOG` | PassLootBiS BiS Manager |
| Attached to a Blizzard panel | match that panel | Honor Tracker panel (`HIGH`) |

Rules behind the table:

- Custom UI should generally render **under** whatever the user is interacting with, but
  **over** the action bars and unit frames. `MEDIUM` + frame level 100 is the house default;
  `LOW` + the same level is for a window parked on screen all session (see the next two
  bullets for why the pair matters on either).
- **"The Blizzard panels" are not one layer, and this is the thing that keeps being got
  wrong.** Bags are `HIGH` and the Interface Options window is `DIALOG`, so `MEDIUM` clears
  them — but the **character sheet and the auction house sit on `MEDIUM` at its default
  level** and only raise within it when you *click* them. A `MEDIUM` + level 100 window
  therefore covers a character sheet opened by keybind or an auction house opened from an
  NPC (owner's report, 2026-08). A window that must never do that goes on `LOW`.
- **`LOW` needs the frame level, and never worked without it.** Blizzard's bars and unit
  frames are on `LOW` themselves — every window in this repo that started on `LOW` *at a
  default level* was drawn through by health bars and action buttons, which is what sent
  them all to `MEDIUM` in the first place. At level 100 they clear those frames' resting
  levels: bar addons such as Bartender default to `MEDIUM` too, and within one strata the
  higher frame level wins, with Blizzard frames and the bar addons in the low single digits.
  100 leaves room for a window's own children, which take 101 upwards.
- **What a level cannot beat is a `toplevel` raise.** Blizzard's bars and unit frames are
  toplevel, so *clicking* one that overlaps a `LOW` window still lifts it in front. That is
  the accepted residual cost of the `LOW` placement, and the reason it is not the default
  for everything.
- **Don't hand-roll the pair — each addon has a helper:** `ns.UI.applyWindowChrome()`
  (`PassLootBiS_Scanner/Core/UI.lua`), `PasslootBiS:ApplyWindowChrome()`
  (`PasslootBiS/Core/PassLoot.lua`), and a file-local `applyWindowChrome()` in
  `!ClientPerfProbe/UI.lua`. Each carries the reasoning. All three park a window at level 100;
  the strata is `MEDIUM` by default, and the two that need `LOW` say so at the call site —
  PassLootBiS passes `WINDOW_STRATA_UNDER_PANELS`, and the cpp meter's file-local constant is
  `LOW` outright, since the meter is the only window that helper serves.
- **Nothing on `MEDIUM` or above may call `Raise()`.** The raise is the drag-freeze restack;
  it is only cheap on a sparse strata. Use a fixed high frame level for front-on-open instead —
  that is what the three helpers do when a show path calls them again. `Raise()` on open is
  still fine on `FULLSCREEN_DIALOG`, which is near-empty.
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
| `Auctionator-Finder-Ascension` | tabs | Largest, heavily XML. Local style puts a space before call parens: `f:SetSize (400, 124)`. Match it. Vendor pricing: `management/addons/auctionator/VENDOR-PRICE-RESEARCH.md` — read before touching the price estimator or the shipped seed. How the addon is put together — upstream vs. local, the two UI worlds, the saved-variable map, and the recipes for adding a tab or a subsystem: `management/addons/auctionator/FRAMEWORK.md` — read before adding anything new. Open request queue (owner's backlog, with what each item means against the current code): `management/addons/auctionator/BACKLOG.md`. |
| `PasslootBiS` | tabs | Ace3. Load order in `Core/Core.xml`; `PassLoot.lua` loads first, so shared helpers go there. BiS Check (the downgrade veto + the run's win ledger) spans both PassLoot addons: `management/addons/passlootbis/BIS-CHECK.md` — read before touching the roll gate or the verdict shape. The three bind-confirmation popups (and why a correct per-rule filter never fired): `management/addons/passlootbis/BIND-CONFIRMS.md`. How the "Not Usable" rule decides usability from tooltip *colour* — and the blank-red-line bug that made it swallow wearable gear: `management/addons/passlootbis/USABLE-SCAN.md` — read before touching `Core/Cache.lua`'s colour test or `Modules/Usable.lua`. In-game test plan for all of the above, incl. every debug command: `management/addons/passlootbis/TESTING.md`. |
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
