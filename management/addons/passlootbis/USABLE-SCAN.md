# The Usable scan — how "can I use this?" is decided, and the bug that hid in it

**Status: closed (2026-08), by choice rather than by exhaustion.** The bug below is
root-caused, fixed and covered by a test. The one loose end is named at the bottom.
If the symptom returns, start at *If it resurfaces*, not from scratch.

Read this before touching `Core/Cache.lua`'s colour test, `Modules/Usable.lua`, or
the `red lines:` field in `/plbisdebug`. The mechanism is not guessable from the
code, and two plausible-looking readings of it were wrong.

## What the rule actually asks

The **Not Usable** rule has one filter, `Usable`, with three settings: Any / Usable /
Unusable. There is no API on 3.3.5 that answers "can this character equip this item"
for gear, so the filter infers it: `Core/Cache.lua` scans the item's tooltip and
declares the item unusable if **any line is painted in the client's unmet-requirement
red**, which is exactly `255, 32, 32` at full alpha (`ColorCheck`).

Three things follow, and all three have already caught someone out:

- **It is an inference from a colour, not a statement of fact.** Whatever the client
  reddens, for whatever reason, reads as "you cannot use this".
- **It reads our own hidden tooltip**, `PasslootBiSTT` (`Libs/Libs.xml`), not the one
  on screen. Nothing else hooks that frame.
- **`GetTextColor()` returns the FontString's base colour** and is blind to inline
  `|cff` escapes inside the text. A line that *looks* red on screen is often not red
  by this test.

## The bug (2026-08)

`GameTooltip` reuses its FontStrings. `ClearLines()` hides them; it does **not** reset
their colour. So a string another item left red still answers red through
`GetTextColor()` when the current item leaves that line blank — and the scan tested
the colour before checking whether there was any text to justify it.

Effect: **Not Usable swallowed gear the player could plainly wear**, intermittently,
depending only on what had been scanned just before it. A leather-wearing Brigand's
`Nightshade Boots of the Slayer` greeded under Not Usable instead of falling through
to Catch All.

Fix: only test the colour of a line that has text. An empty line states no
requirement, whatever colour it is left in.

### Why it took six rounds to see

Three separate things hid it, and each is worth remembering on its own:

1. **The outcome was right anyway.** `Not Usable` and `Catch All` both greed, so the
   wrong rule still cast the right roll. Nothing observable in play was wrong. This
   would have become a real bug the moment those two rules diverged — if Not Usable
   is ever set to pass or disenchant, correctness starts mattering immediately.
2. **The trace lied.** `Modules/Usable.lua` computed the verdict correctly but printed
   a hardcoded `2`, so every item ever scanned traced `Usable: 2 (Usable)` — including
   the ones that rule had just declared unusable. A report that contradicted itself
   read as noise rather than as evidence.
3. **The verdict carried no evidence.** Once the trace was honest it said *what* was
   decided but not *why*. Printing the offending red line is what ended the hunt,
   because the answer turned out to be `red line: R4 ` — red, with **no text at all**.

## Reading a `red lines:` field

Format is `<column><index> <text>`, several joined by ` | `, capped at five.

| Seen | Means |
|---|---|
| `R4 Mail`, `R3 Mail` | An armour class this character cannot wear. The armour *type* sits in the right column of the armour line and the client reddens just that word. Commonest refusal by far. |
| `L3 Requires Blacksmithing (200)` | A profession or skill requirement not met. |
| *(an already-known recipe)* | Reddens its own line; correctly unusable. |
| `R4` with empty text | **The bug above.** Should be impossible now; if you see it, the text guard in `getLine` has been lost. |

**The index is not fixed and must never be matched on.** The same armour refusal was
measured at `R4` on one item and `R3` on another, purely because one carried an extra
line above the armour line. The position is a label for a human reading a report.

### Two readings that were wrong

Recorded because both are natural, and someone will re-derive them:

- **"The column tells you the source."** The guess was that a client refusal lives in
  the left column near the top, so a right-column red would mean an addon had bolted a
  line on. The very first measurement was `R4`. The column says nothing about the
  source.
- **"The BiS Scanner's downgrade text is leaking in."** It is not, twice over.
  `PassLootBiS_Scanner/Core/Tooltip.lua` hooks `GameTooltip` and `ItemRefTooltip`
  only, and `HookScript` is per frame — the scan reads `PasslootBiSTT`. And the
  scanner writes through `setTopRight` with the base colour `COLOR_NEU`
  `(0.90, 0.90, 0.60)`, its red being an inline `|cff` escape. Even on the same frame
  it would not match. Confirmed in play: a **-50%** downgrade scores `usable: yes`.
- Likewise **forge labels do not trip it.** A Bloodforged item whose visible tooltip
  carries red "heroic bloodforged" text scores `usable: yes`; the same forge on a Mail
  item still reports `R3 Mail`. Whatever reddens that label on screen is not
  `255,32,32` in our tooltip.

## What is covered

`tools/usable-smoke.lua` — 14 assertions, bare `lua5.1`, stubbed tooltip, no client:

```
lua5.1 management/addons/passlootbis/tools/usable-smoke.lua
```

Case 1 is the exact tooltip that shipped broken. The net was verified by defeating the
text guard and confirming case 1 fails — a test that has never been seen to fail is
not yet known to test anything.

## If it resurfaces

The whole point of the `red lines:` field is that the next occurrence costs one
shift-click rather than a dungeon:

```
/plbisdebug item        then shift-click the item
```

`usable: no` on something wearable, and the field names the line responsible. Then:

- **Empty text** → the `getLine` text guard has regressed. `usable-smoke.lua` case 1.
- **A line that is a real requirement** → not a bug; add it to the table above.
- **A line that is not a requirement** → the vocabulary has grown a case the colour
  test cannot distinguish. That is the point at which the heuristic itself needs
  replacing rather than patching, because red is all it has to go on.

## The loose end

The original `Nightshade Boots of the Slayer` were **never re-tested** — another player
won them, so their red line was never captured. The diagnosis is inference: a leather
item on a leather wearer, intermittent, order-dependent, and a mechanism that produces
exactly that. It fits, and no competing explanation survived the controls. But it was
not observed directly, and this note exists so that is not later remembered as
certainty.
