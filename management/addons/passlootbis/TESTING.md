# In-game test plan — BoP confirms, BiS Check, enchant strip

Nothing in this repo can run the 3.3.5 client, so this is the list that turns
"should work" into "does work". Written to be picked up cold in a fresh session — if
you are that session, read `BIND-CONFIRMS.md` and `BIS-CHECK.md` first for why any
of it is shaped the way it is.

## Results so far (2026-08, owner)

Rounds 1–6. A "round" is one pass through the steps below with a build in the client.

| Check | Result |
|---|---|
| A. Loads | **PASS** — no errors, report renders, `[Contract self-test]` all `PASS`, "BiS Check" row present |
| B. Roll-bind popup | **not run** — needs a BoP boss drop |
| C. Pickup-bind popup | **not run** — but the three confirm boxes it exposed were merged into one (below) |
| D. Enchant strip | measured **safe** (link and instance agreed on all 17 slots, 2 carrying enchant value) — now **on by default**, after fixing the two bugs that made it look inert; see `BIS-CHECK.md` |
| E. Win ledger | **not run** |
| F. BiS Check dry run | **PASS** — a BiS glove at -4% vs equipped gave `WOULD VETO`; a non-list item did not fire |
| G. Preview | **not run** |
| H. Usable dry run (round 3) | **PASS** — wearable downgrade → `usable: yes`; unwearable Mail → `usable: no`, `red line: R4 Mail` |
| H. Usable dry run (round 4) | **BUG FOUND** — a Bloodforged variant reported `red line: R4 ` with empty text: a blank line left red by an earlier item. Fixed; see §4 |
| H. Usable dry run (round 5) | **PASS** — same Bloodforged item after the fix: `usable: yes   (2 Usable)`, no red lines. Forge labels do not trip the colour test |
| H. Usable dry run (round 6) | **PASS** — `Bloodforged Pyremail Wristguards` (Mail): `usable: no`, `red lines: R3 Mail`. Forged *and* unwearable is still caught, and the index moved R4 → R3 |

Two changes came out of round 1, so the steps below are written against them:

- **The three bind-confirm boxes are now one**, `Auto-Confirm Bind Popups`, default
  ON, covering the roll prompt, the pickup prompt and the popup-queue bit.
- **"Ignore enchants when scoring" is ON by default**, and now strips *both* sides
  of a compare rather than only the equipped one. Ticking it used to look like it
  did nothing, for two reasons that are both fixed: the tooltip's equipped-score
  cache was not rebuilt when the box changed, and the hovered item itself was never
  stripped. Step D is now a check on a shipped default, not a switch to decide.

## 0. Before you start

Copy **both** addon folders across — the two are a designed pair and this branch
changes the contract between them. A new `PasslootBiS` against an old
`PassLootBiS_Scanner` (or vice versa) silently loses BiS Check: the `downgrade`
field is dropped on arrival with no error. `/plbisdebug` reports the mismatch under
`[Contract self-test]`.

New files that must be present, or the addon will not load correctly:
`PasslootBiS/Core/BiSCleanup.lua`, `PasslootBiS/Core/DebugReport.lua`,
`PassLootBiS_Scanner/Core/WonLedger.lua`, `PassLootBiS_Scanner/Core/ItemLink.lua`.

Then `/plbisdebug on` and leave it on for the whole session. It buffers silently —
it will not spam your chat.

## 0b. Offline checks (no client needed)

Run both from the repo root before shipping a change to the report or the usable
scan. Neither needs WoW; both exit non-zero on failure.

```
lua5.1 management/addons/passlootbis/tools/report-smoke.lua
lua5.1 management/addons/passlootbis/tools/usable-smoke.lua
```

`usable-smoke.lua` is the regression net for the blank-red-line bug in §4. Its case 1
is that exact tooltip — if it ever fails again, `Not Usable` is silently swallowing
gear the player can wear.

## 1. Commands

| Command | What it does |
|---|---|
| `/plbisdebug` | **The one that matters.** Opens the report in a copy box — click the text, Ctrl+A, Ctrl+C, paste it back |
| `/plbisdebug on` \| `off` | Start / stop collecting the trace (buffered silently) |
| `/plbisdebug chat` | Also echo trace lines live, if you want to watch during a pull |
| `/plbisdebug clear` | Empty the trace — use between test cases to keep reports short |
| `/plbisdebug item <link>` | Dry-run one item through BiS Check. **Shift-click the item into the chat box after typing the command** |
| `/plbisadvisor` | List advisors + trust modes |
| `/plbisadvisor on` \| `off` | Master switch for the whole advisor gate |
| `/plbisscan options` (or `/plbs options`) | Scanner settings window |
| `/plbisscan spec` | Check / set the spec whose stat weights are used |
| `/plbismgr` | BiS Manager |

Nothing above writes to SavedVariables. A `/reload` wipes the trace.

## 2. Checks, in the order worth doing them

### A. It loads at all
1. `/reload`, watch for Lua errors. Then `/plbisdebug`.
2. In the report: `[Advisor]` shows the gate enabled and `PLScanner` registered;
   `[Scanner]` shows your class/spec and `weights: yes`; `[Contract self-test]` is
   all `PASS`.
3. Interface → AddOns → PassLoot (BiS) → Options: there is **one** bind-confirm
   toggle, **Auto-Confirm Bind Popups**, and it is **ON**. If you see the old three
   boxes, the copied-over folder is stale. `[Bind confirms]` in the report says the
   same thing in one line — and an existing profile that had the old roll box turned
   *off* should come through as `no`, not `yes`.
4. Rules page: the advisor status panel has a **fourth row, "BiS Check"**, with a
   ticked checkbox.

**Copy the report out now** — that is the baseline, and it is worth having even if
everything looks right.

### B. The roll-bind popup (the reported bug)
The whole point: a greed roll on boss loot should no longer stop for a click.

5. Run a dungeon. On a **BoP** boss drop that your "Catch All → Greed" rule covers,
   the roll should be cast and confirmed with **no popup left on screen**.
   - Make a point of watching a **Bloodforged / Heroic / Mythic / Ascended** drop go
     past with the trace on. That combination used to throw and skip the roll
     entirely (`Modules/ExceptionalItem.lua`); it should now trace one
     `(ExceptionalItem) Exceptionaltem: bloodforged=... ` line and roll normally.
6. If a popup still appears, `/plbisdebug` immediately and copy it out. The lines to
   look for in `[Trace]`:
   - `CONFIRM_LOOT_ROLL: auto-confirming roll N (addon-cast)` — we answered it; if a
     popup is still up, the hide failed rather than the confirm.
   - `... (hand-cast)` — a roll **you** clicked. Also answered now; the prompt no
     longer survives just because the click was yours.
   - `... (addon-cast, link changed)` / `... (addon-cast, roll no longer live)` — the
     prompt was answered, but our ledger and the client disagree about that rollID.
     Nothing depends on it any more, so nothing breaks — report it anyway, it is the
     open question in `BIND-CONFIRMS.md`.
   - **no `CONFIRM_LOOT_ROLL` line at all** — the event never reached us, and my
     whole diagnosis is wrong. That is the most valuable failure to report.
   - **no lines at all for an item that dropped** — evaluation threw before the first
     `Checking rule`. That is what a forged drop used to do while tracing was on
     (`BIND-CONFIRMS.md`, second round); a **red Lua error** on screen is the tell,
     and it is worth pasting whatever the error says even if the run looks fine.
7. Multi-drop: a boss dropping several BoP items at once should need **zero** clicks.
   - Then roll **Greed by hand** on a BoP drop your rules passed on. That prompt
     should answer itself too — the behaviour this round added — and the trace line
     should read `(hand-cast)`. A **disenchant** rolled by hand still asks; that one
     is deliberate.

### C. The pickup-bind popup (same setting, on by default now)
8. Nothing to tick — **Auto-Confirm Bind Popups** covers this prompt too. If you
   would rather BoP pickups kept asking, that is the box to untick, and it takes the
   roll confirm with it.
9. Loot a BoP item straight off a corpse. The "this item will bind to you" prompt
   should answer itself. Look for `LOOT_BIND_CONFIRM: auto-confirming loot slot N`.
10. If the prompt lingers on screen after the item is looted, the confirm worked but
    the hide did not — say so, it is a one-line fix (the dialog's `data` is not the
    slot on this client).

### D. Enchant strip — now the default; confirm it is actually taking effect
`/plbisscan options` → **Ignore enchants when scoring**, which should already be
ticked (an existing saved DB is flipped on once, then left alone).

11. `/plbisdebug`, read `[Enchant strip check]`. Every equipped slot scored three
    ways: `real` (true instance), `link`, `stripped`. `real` vs `link` is the test —
    same item, two routes. Round 1 said *"link and instance agree on every slot"*.
    If a later report says *"N slot(s) score differently"*, **untick the box** and
    send the table: `SetHyperlink` would be reporting cached/nominal stats for
    scaled items, which is a worse error than the skew it fixes.
12. **The visible check, which round 1 could not do:** hover an item you are wearing
    that has an enchant on it. Its tooltip score should now equal the `stripped`
    column for that slot, not the `real` one. (Feet in round 1: **47.3**, not 58.3.)
    Toggle the box off and re-hover — it should go straight back to `real`, with no
    `/reload`. If it needs a reload, the cache signature fix did not take.
13. `/plbisdebug item ` + shift-click an item **you are currently wearing**. It
    should read roughly `0%`, not a large upgrade over itself. That was the clearest
    symptom of the candidate side not being stripped.
14. `stripped` vs `link` is how much enchant is being kept out of the compare — two
    slots in round 1. Re-read it after a big gear change.

### E. Win ledger (testable without any BiS drop)
15. `/plbisdebug clear`, then loot 2–3 pieces of equippable gear in one dungeon.
16. `/plbisdebug` → `[This run]` should list them under `won <SLOT>` with scores.
    Empty after looting real gear = the `CHAT_MSG_LOOT` patterns do not match on
    this client. Copy the report; that is a self-contained fix.
17. Leave the zone, `/plbisdebug` again — the ledger should be **empty**.

### F. BiS Check (needs a stale BiS entry — use the dry run instead)
The veto needs one specific item to drop, so force the situation instead:

18. `/plbisdebug item ` then shift-click **an item on your BiS list that is worse
    than what you are wearing** (an old entry you have upgraded past is ideal).
19. Expect `on a rolling BiS list: yes`, and
    `BiS Check WOULD VETO this roll: -N%`. If it says it would not fire, the report
    says which of the three preconditions failed (scannable / weights / filtered).
20. Sanity control: dry-run something **not** on your BiS list — it must say
    `BiS Check would not fire (not on a rolling BiS list)`.
21. If a real veto does fire in a dungeon, the popup should be **red**, headed
    "BiS, but lower", with a **down arrow**, and it must **not** auto-roll. If the
    arrow is a blank box, the texture path is wrong — cosmetic, one line.
22. Let one expire without clicking: it should cast **Greed**, not Need.
23. Then leave the zone: the **"BiS list looks out of date"** window should appear
    listing what was vetoed. "Keep them" changes nothing; "Stop rolling these"
    unticks those items (they stay on the list — check in `/plbismgr`).

### G. Preview (no dungeon needed)
24. Rules page → **Show Loot Advisor**. Press it three times: green "Gear Upgrade",
    gold "High Value", red "BiS, but lower". That is the cheapest way to check the
    down arrow renders.

### H. The Usable verdict (no dungeon needed)
Full background — how the check works, what its red lines mean, and the bug that hid
in it — is `USABLE-SCAN.md`. This is just the test.

24b. `/plbisdebug item ` then shift-click any item: bags, bank, a chat link, an AH
    listing. The report prints the `Not Usable` rule's own verdict on it, without
    waiting for it to drop:

    ```
      usable: no   (3 Unusable)   red lines: R4 Mail
    ```

    That comes from `Modules/Usable.lua` itself, not a copy of its logic, so it is
    the same answer a live roll would get.
25. Shift-click a few things you can plainly wear and a few you cannot. **The verdict
    must track.** An armour class you cannot use names itself (`R4 Mail`); an
    already-known recipe or one needing a profession you lack names that requirement.
26. **Anything wearable that comes back `usable: no` is the finding.** Copy the
    `red lines:` field — it names the tooltip line responsible, and
    `USABLE-SCAN.md` § *If it resurfaces* says what each kind means.
27. With the trace on, let a dungeon's loot go past and check the same verdict appears
    per item as `(Usable) Usable: N (...)`. **N must vary** — it once printed a
    hardcoded `2` for everything, which is what made a self-contradicting report look
    like noise.

## 3. What to send back

`/plbisdebug` after any failure, copied whole. The report already carries the
settings, the advisor wiring, the BiS lists, the run ledger and the trace, so a
single paste is usually the entire diagnosis — no need to describe it in prose too.

## 4. Known unverified

Genuinely open, highest-risk first. Things that were investigated and settled are in
§5, so this list stays a to-do rather than an archive.

- **Both confirm paths.** Neither `CONFIRM_LOOT_ROLL: auto-confirming roll N` nor
  `LOOT_BIND_CONFIRM: auto-confirming loot slot N` has been seen in a trace yet, so
  the root cause in `BIND-CONFIRMS.md` is still a diagnosis. Steps B and C.
- **The merged setting itself**, including the migration of an existing profile
  (step A3) — reasoned and syntax-checked only.
- **`LOOT_BIND` / `CONFIRM_LOOT_ROLL` popup hiding** — the confirm is event-driven
  and solid; the *hide* assumes the client stores the slot/rollID as the dialog's
  `data`.
- **`LOOT_ITEM_*` chat patterns** feeding the ledger, if Ascension reworded loot
  messages. Round 1 is *not* evidence against them: the one item won that run was
  `Jasper Link of the Arcane`, an intellect ring worth 0 to a Brigand, and
  `WonLedger.record` drops a zero score on purpose. An empty `[This run]` there is
  the designed behaviour, not a missed match — step E still needs gear the spec
  actually scores.
- **`ZONE_CHANGED_NEW_AREA` timing** on the way out of an instance.
- **`Interface\Buttons\Arrow-Down-Up`** existing in this build.
- **The 21.9 — target half RESOLVED, score half still untested.** In the round-1
  feet dry run the report read `score 58.3 vs target 21.9` with **Ignore enchants
  ON**, where the `[Enchant strip check]` put those same equipped boots at `real 58.3
  / link 58.3 / stripped 47.3` — so the target should have been 47.3. Round 3, same
  equipped boots, same setting, dry-running `Shadefiend Boots`:

  ```
  score 23.5 vs target 47.3  -> -50%
  target from equipped: slot 8 = 47.3
  ```

  The target is now exactly the stripped number. **What that does NOT yet prove is
  the other side of the compare**: `Shadefiend Boots` carries no enchant, so its
  `score` is the same either way. To close it, dry-run your own **equipped** Pads of
  the Dread Wolf — with the strip working it must read `score 47.3`, not `58.3`. That
  is a five-second check and it is the one still outstanding.

  Nothing else explains 21.9 comfortably. The win ledger was empty, `INVTYPE_FEET`
  is a single-slot group with nothing to pick the wrong member of, and the gloves
  dry run in the second report agreed exactly (43.7 vs target 45.8 = the equipped
  gloves) — but gloves carry no enchant, so that run never went near the strip path.
  Every candidate explanation left is about the stripped read: `SetHyperlink`
  returning nominal, unscaled stats for a scaled item when the cache is cold (which
  is precisely what LibScaledStats warns about and what `real` vs `link` is supposed
  to catch — a snapshot can only prove it was faithful *that time*), or the strip
  landing on the wrong link field on Ascension's layout.

  It matters twice: a target read too low makes BiS Check **under**-fire (everything
  looks like an upgrade), and if the strip is the cause then "measured safe" is not
  safe enough and the box should come back off.

  **That comparison has now been made and it agreed** — round 3's `target from
  equipped: slot 8 = 47.3` is exactly the `stripped` column for slot 8 in the same
  report, so round 1's 21.9 was a one-off cold read on the target side.

  **What is left:** dry-run your own **equipped** `Pads of the Dread Wolf` — one of
  only two slots carrying enchant value, so it is the item that can tell the two
  reads apart. With the strip working it must come back `score 47.3`, not `58.3`.
  - `47.3` → the strip works on both sides; close this entry.
  - `58.3` → the hovered/dry-run side is not being stripped after all, and the
    compare is mixing a stripped target with an unstripped score. **Untick Ignore
    enchants** and send both reports.

## 5. Settled — do not re-open without new evidence

- **The Usable / "Not Usable" investigation** (rounds 1–6): the trace that printed a
  hardcoded verdict, the blank red tooltip line that made wearable gear read as
  unusable, and the two suspects ruled out along the way (the BiS Scanner's own red
  annotation, and forge labels). Full write-up, the `red lines:` vocabulary, and what
  to do if the symptom returns: **`USABLE-SCAN.md`**. Closed by choice, with one
  loose end named there.
- **A ring that changed score between two reports.** Round 2 scored an equipped
  `Innervating Band` at 32.5 where round 1 had 24.3, every other slot byte-identical.
  Not a scoring bug: Ascension awards a Dungeon Spoils container at the end of a run,
  and the owner pulled the **Mythic** forge of that ring from it and equipped it. An
  equipped item can legitimately become a higher forge of itself between two reports.
- **A Bloodforged variant scoring the same as its base item.** Looked wrong for an
  item said to trade PvE power for PvP power. The PvE/PvP power weighting is switched
  off on this character, so the forged half contributes nothing either way, and these
  items roll variable stats. Two independent reasons for the scores to land together.
