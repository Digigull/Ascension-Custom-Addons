# Window-drag freeze (Ascension 3.3.5): the cause is `SetToplevel(true)` on a populated strata

**Portable hand-off note.** Self-contained — safe to paste into an issue/PR on any addon repo.
This is the **confirmed** result; it supersedes both the backdrop note (`BACKDROP-FIX.md`) and an
interim "dropdown children" hypothesis. Neither was the cause.

---

## TL;DR

- On **Ascension 3.3.5**, a hand-rolled addon window freezes the whole client for **~0.6–2.6 s
  the first time it is dragged each session** (re-colds on `/reload`). Pure engine-side CPU — no
  addon Lua on the stack.
- **Cause (measured, single-variable):** the window calls **`SetToplevel(true)`** *and* sits on a
  **populated frame strata** (e.g. `HIGH`). The click/drag raises the frame; raising a toplevel
  frame into a **crowded strata** restacks the whole strata in a ~1 s engine pass. It is the
  combination — remove **either** and the big freeze is gone.
- **Not the backdrop, not the children.** An **empty** `HIGH`+toplevel frame (zero children, any
  backdrop) still froze **1273 ms**. Backdrop, dropdowns, checkboxes, sliders, drag-wiring, and the
  "guarded mouse event" are all exonerated.
- **`FULLSCREEN_DIALOG` alone does NOT get you to zero.** Moving to the sparse strata kills the big
  cold freeze but leaves a **~50 ms strata-restack on EVERY click/drag** (because `SetToplevel`
  re-raises the frame each time). That recurs as a **repeatable per-drag micro-spike** — small, but
  the owner *feels* it on a window they reposition often.
- **The one rule that matters: don't call `SetToplevel(true)`.** Drop it and there is no raise, so
  there is no restack, so the cost is zero — cold and warm, on *any* strata.
- **Corollary (this is the useful part): once the flag is gone, strata becomes a free choice.**
  Variant B below kept the crowded `HIGH` strata and was perfectly smooth, because nothing ever
  raised. So you can pick strata for **layering** rather than for performance. See
  "Strata is a UI decision once toplevel is gone".
- **STATUS — CONFIRMED IN-GAME** for the original three PassLoot windows (owner-verified, `/cpp`
  logs no `sus=DRAG` spike). Subsequently rolled out repo-wide across five addons; that wider
  rollout is **applied but not yet in-game verified** — see "Repo-wide rollout" for exactly which
  is which.

## The measurement

Four movable frames, **one construction axis varied each**, dragged once from a cold client
(`sus=DRAG` spike read from ClientPerfProbe; `dt` = frozen frame time):

| Variant | Strata | `SetToplevel` | Children | Result |
|---|---|---|---|---|
| **A** | `HIGH` | true | full (~20 widgets) | **FREEZE — `dt=864 ms`** |
| **B** | `HIGH` | **false** | full | **smooth — 0 spikes** |
| **C** | **`FULLSCREEN_DIALOG`** | true | full | **smooth — `dt=53 ms`** (imperceptible cold, but NON-zero) |
| **D** | `HIGH` | true | **none** | **FREEZE — `dt=1273 ms`** |

Reproduced on retest (A and D freeze consistently; B and C smooth consistently). Every spike:
`cpu=` empty (no addon Lua), `mouse=held`, heap ≈ 0 — pure engine CPU, exactly the profile of an
engine-side first-layout/restack.

- **D is the key row.** An empty frame — no backdrop content, no children — still froze, and worse
  than A. So the cost is **not** anything *inside* the window. It is the frame's own raise/restack.
- **B and C are the two independent cures for the *cold freeze*.** No raise (B) → nothing to
  restack. Sparse strata (C) → the raise restacks almost nothing.
- **But C is not 0 — it is 53 ms.** That number matters: a `SetToplevel` frame re-raises on *every*
  click, so C pays that 53 ms **on every drag**, not once. B pays nothing, ever, because there is no
  raise at all.

## Why `HIGH` + toplevel is expensive

`SetToplevel(true)` tells the engine to **raise the frame above its strata siblings whenever it is
clicked** — and a drag is a click. On 3.3.5 that raise re-sorts the frame-level ordering of the
**entire strata**. `HIGH` is where most of the default Blizzard UI and many addons live, so the
first restack of that populated list is a large one-time engine pass. `FULLSCREEN_DIALOG` is a
near-empty strata (a few modal dialogs), so the identical raise restacks almost nothing (~53 ms).

The corollary the four-variant table makes explicit: the restack cost scales with how many frames
are in the strata, and it is paid **once per raise**. On `FULLSCREEN_DIALOG` the strata is nearly
empty so each raise is cheap — but it is not free, and `SetToplevel` triggers a raise on *every*
click/drag. The only way to pay **zero** is to not raise at all (drop `SetToplevel`).

## Field follow-up (measured in-game): `FULLSCREEN_DIALOG`+toplevel still micro-spikes per drag

After applying the behavior-preserving fix (variant C: `FULLSCREEN_DIALOG` + keep `SetToplevel`) to
three hand-rolled windows, two floating windows went from a ~1 s cold freeze to smooth — fixed for
practical purposes. But a **settings-style window the owner drags frequently** (a BiS-list manager)
**still produced a perceptible spike on every drag-start**. That is variant C's residual 53 ms,
paid *per drag* because `SetToplevel` re-raises the frame each time you grab it.

**Root cause of the residual:** the window kept `SetToplevel(true)` even though it never needed
click-to-raise. It is a **singleton** launched from the Blizzard Interface Options panel, and it
does not stack with sibling windows.

**Two facts that make dropping `SetToplevel` safe:**

1. **Strata alone provides "render in front", not the toplevel flag.** 3.3.5 strata order (low→high)
   is `BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP`. The
   Blizzard Interface Options window lives on `DIALOG`. A window on `FULLSCREEN_DIALOG` is therefore
   **always above it by strata**, with or without `SetToplevel`. `SetToplevel` only controls
   click-to-raise *within a single strata* — which a singleton doesn't use.
2. **A one-time `Raise()` on open still works without the flag.** `frame:Raise()` sets the frame to
   the top of its strata's level ordering; call it once in the show path and the window reliably
   comes to front when opened. That is one cheap restack in a near-empty strata on open, not one on
   every drag.

**Result (owner-verified in-game):** the three original PassLoot windows cost **zero**
strata-restacks on drag — `/cpp` logs no `sus=DRAG` spike, cold or warm.

## The fix

**Before:**

```lua
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
```

**Option 1 — behavior-preserving (keeps click-to-raise; ~50 ms per drag on `FULLSCREEN_DIALOG`):**

```lua
frame:SetFrameStrata("FULLSCREEN_DIALOG")   -- sparse strata: the toplevel raise is now cheap
frame:SetToplevel(true)
```

**Option 2 — cleanest, TRUE 0 spikes (a singleton window that doesn't need click-to-raise):**

```lua
frame:SetFrameStrata("FULLSCREEN_DIALOG")   -- high strata => still renders above DIALOG panels
-- no SetToplevel(true): nothing to re-raise on click, so no per-drag restack
frame:Raise()                               -- (optional) once, in the show/open path
```

Prefer **Option 2** for the common case. Use Option 1 only when several windows share one strata and
must reorder on click. (Details never calls `SetToplevel` at all, and never freezes.) Apply to
**every** hand-rolled window that pairs `SetToplevel(true)` with a populated strata. Nothing else
about the window needs to change — backdrop, children, and drag-wiring are irrelevant.

## Five rules learned during the repo-wide rollout

The original note covered draggable windows. Applying it across five addons surfaced five more
cases that the "drag" framing hides.

**1. The raise fires on *click*, not just on drag — so non-draggable frames pay it too.**
A drag is just a click that moves. A `toplevel` confirm dialog on a populated strata restacks that
strata every time you click it, with no dragging involved. Any `toplevel` frame on a crowded strata
is suspect, movable or not. (Found on four Auctionator dialogs sitting on `DIALOG`.)

**2. `Raise()` restacks too — never call it on a populated strata.**
`Raise()` is recommended above as the replacement for click-to-raise, and on a sparse strata it is
cheap. But it is the *same operation* the freeze is made of. On a crowded strata like `HIGH` a
one-time `Raise()` in a show path costs the same ~1 s pass you just removed. Rule: `Raise()` on
sparse strata only; on a populated strata, rely on strata ordering and don't call it at all.

**3. Never put `SetToplevel` on a scrim/mask frame.**
A mask (the grey panel behind a modal that swallows clicks) must sit *below* the dialog it masks.
`toplevel` makes it raise when clicked — lifting the mask **above** the dialog it exists to mask and
blocking the thing you are trying to click. Here it is a correctness bug that also happens to cost a
restack. Masks should have no `toplevel` and should keep a strata below their dialog.

**4. A window opened from inside the Interface Options panel cannot go low.**
If a button in the Blizzard options panel (`DIALOG`) opens your window and does not close the panel,
that window must stay above `DIALOG` or it opens invisibly behind the panel you just clicked. And
`Raise()` will not rescue it — `Raise()` orders within a strata and **cannot cross strata**.

**5. Notifications and copy/paste popups are exceptions to any "render low" house style.**
A toast that fires while your bags are open, and a copy box you open to select text from, both need
to be *seen*. Consistency is not worth a missed alert or an unreadable export window.

## Strata is a UI decision once toplevel is gone

This is the practical payoff of variant B, and it is easy to miss.

While the toplevel flag is present, the strata is **load-bearing for performance**: it is the only
thing keeping the restack small. Once the flag is gone, nothing raises, nothing restacks, and the
strata stops mattering for performance entirely — variant B sat on crowded `HIGH` and was smooth.

So after dropping `SetToplevel` you may choose strata purely for **layering**:

```lua
-- strata order, low → high:
-- WORLD < BACKGROUND < LOW < MEDIUM < HIGH < DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP
frame:SetFrameStrata("LOW")   -- below the character panel/bags/world map, above the 3D world
frame:Raise()                 -- (once, on open) orders among LOW siblings only; cannot cross strata
```

`LOW` is the right default for a **persistent window you leave open while playing** (a meter, a
floating log): the default Blizzard panels render over it, which is what players expect from custom
UI. Keep `FULLSCREEN_DIALOG` for windows you **deliberately open and read** (settings panels,
copy/paste popups) and for anything launched from the options panel (rule 4).

**This is spike-free only because there is no `SetToplevel`.** A `LOW` + `SetToplevel` window would
restack the `LOW` strata on every drag — the same mechanism as the `HIGH` freeze, just cheaper.
If you ever restore the flag, the strata becomes load-bearing again.

## Repo-wide rollout (Ascension-Custom-Addons)

**In-game verified** (owner-tested, `/cpp` clean, cold and warm):

| Window | Addon | State |
|---|---|---|
| BiS Manager | PassLootBiS | Option 2 — `FULLSCREEN_DIALOG`, no toplevel, `Raise()` on open |
| Loot Window | PassLootBiS | Option 2 (since moved to `LOW`, see below — **re-test**) |
| Roll-advisor popup | PassLootBiS | Option 2, no `Raise()` needed (non-overlapping slots) |

**Applied but NOT yet in-game verified** — reasoned from the mechanism above, not measured:

| Window / frame | Addon | Change |
|---|---|---|
| `Atr_ProfitMarginPopup` | Auctionator | **The only other true variant-A frame found** — movable, `toplevel`, `DIALOG`. Moved to `FULLSCREEN_DIALOG` + dropped toplevel |
| 3 confirm dialogs | Auctionator | `DIALOG` → `FULLSCREEN_DIALOG`, toplevel kept (rule 1) |
| `Atr_Mask` | Auctionator | Dropped toplevel, strata left below the dialogs (rule 3) |
| Options + Filter windows | BiS Scanner | Dropped toplevel, `raiseOnOpen()` in show paths; strata → `LOW` |
| Export / detail / glossary | ClientPerfProbe | Dropped toplevel, `Raise()` on open |
| 2 dropdown menus | ClientPerfProbe | Dropped toplevel (no `Raise()` — one menu open at a time) |
| Loot Window | PassLootBiS | Strata → `LOW` (persistent log) |
| PvP points panel | Honor Tracker | `DIALOG` → `HIGH` to match the character panel it attaches to. Deliberately **no** `Raise()` (rule 2) |

**Deliberately unchanged, with reasons:**

- **BiS Manager** stays `FULLSCREEN_DIALOG` — opened from inside the options panel (rule 4).
- **Roll-advisor popup** stays high — appears during a live roll with a timer running.
- **BiS Scanner alert + all copy/paste boxes** stay high (rule 5).
- **Auctionator** keeps its own layering — it attaches to the Blizzard auction house window and
  should follow that chrome.

## How to verify

Cold client (or `/reload`), then drag the window once, then drag it a few more times:

- **Broken (`HIGH` + toplevel):** a ~0.6–2.6 s hitch on the first drag.
- **Option 1 (`FULLSCREEN_DIALOG` + toplevel):** no cold freeze, but a ~50 ms micro-spike on
  **every** drag-start (a `sus=DRAG` spike of ~50 ms in `/cpp`, repeatable).
- **Option 2 (no toplevel):** nothing logs on any drag — 0 spikes, cold or warm.

With ClientPerfProbe, watch `/cpp`: Option 1 logs a small `sus=DRAG` spike each drag; Option 2 logs
none. The four-way isolation harness that produced the numbers below (`/plbisscan dragtest`,
`Core/DragTest.lua`) has been retired now that the cause is settled — this document is the record.
If a future window ever needs re-isolating, rebuild it from the variant table above: four clones of
the suspect window differing in exactly one axis each (strata, `SetToplevel`, children).

For the rollout above, the layering changes also need an **eyeball** check that `/cpp` cannot give
you: confirm the `LOW` windows really do sit under bags and the character panel, that the Honor
Tracker panel is still visible over the character panel, and that each Auctionator dialog still
appears above its mask.

## Caveats

- **Client-specific:** Ascension 3.3.5; a non-issue on retail (the strata restack was optimized
  long ago).
- The cost is **engine-side** — the fix *avoids triggering* the restack, it doesn't optimize it.
- Dropping `SetToplevel` removes click-to-raise *within the strata*. For a singleton or
  non-overlapping window that is a no-op in practice; only reach for Option 1 if you actually rely
  on click-ordering between sibling windows.

## Optional house styling (dark background)

A cosmetic preference applied to the hand-rolled windows in these addons. **This does not fix the
freeze** — the backdrop was explicitly exonerated above. Purely optional.

Replace the ornate gold `UI-DialogBox` textures with the flat tooltip background + a 1px `WHITE8X8`
border, tinted near-black:

```lua
frame:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    tile = true, tileSize = 64, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
})
frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)       -- dark, mostly opaque
frame:SetBackdropBorderColor(0.30, 0.30, 0.34, 1)    -- thin muted border
```

Dropping `edgeSize` from 32 to 1 does **not** move any child widgets: children are anchored with
explicit pixel offsets to the frame edges, not to the backdrop insets. Titles anchored for a chunky
32px border may read as slightly top-heavy against a 1px one.

**Where it was applied:** Honor Tracker panel; all four BiS Scanner windows; the three PassLootBiS
hand-rolled windows. In both addons with more than one window the recipe was centralized
(`ns.UI.applyDarkBackdrop` / `PasslootBiS:ApplyDarkBackdrop`) so one edit re-themes everything.

**Where it was deliberately NOT applied:** frames embedded in the **Blizzard Interface Options
panel**. A dark box on Blizzard's stock parchment reads as a seam, not a theme. Restyle floating
windows you own; leave shared Blizzard chrome alone. Same reasoning keeps Auctionator's inline
panels (which live inside the auction house frame) on their stock look.

---

*Measured while building `!ClientPerfProbe` (a WoW 3.3.5 client-stutter measurement addon) and fixed
in `Digigull/BiS-Scanner` and the PassLoot (BiS) addon. Isolation data: the (since-retired)
`/plbisscan dragtest` harness, Wetlands, cold `/reload` per variant. **The original three PassLoot windows are confirmed
spike-free in-game.** The wider rollout across the other addons is applied and reasoned from the
same mechanism, but is pending in-game verification — the tables above mark which is which. Full
record in the BiS-Scanner repo's `docs/FINDINGS.md`.*
