# In-game test plan — BoP confirms, BiS Check, enchant strip

Nothing in this repo can run the 3.3.5 client, so this is the list that turns
"should work" into "does work". Written to be picked up cold in a fresh session — if
you are that session, read `BIND-CONFIRMS.md` and `BIS-CHECK.md` first for why any
of it is shaped the way it is.

## Round 1 results (2026-08, owner)

| Check | Result |
|---|---|
| A. Loads | **PASS** — no errors, report renders, `[Contract self-test]` all `PASS`, "BiS Check" row present |
| B. Roll-bind popup | **not run** — needs a BoP boss drop |
| C. Pickup-bind popup | **not run** — but the three confirm boxes it exposed were merged into one (below) |
| D. Enchant strip | measured **safe** (link and instance agreed on all 17 slots, 2 carrying enchant value) — and then **shelved** anyway; see `BIS-CHECK.md` |
| E. Win ledger | **not run** |
| F. BiS Check dry run | **PASS** — a BiS glove at -4% vs equipped gave `WOULD VETO`; a non-list item did not fire |
| G. Preview | **not run** |

Two changes came out of that round, so steps below are written against them:

- **The three bind-confirm boxes are now one**, `Auto-Confirm Bind Popups`, default
  ON, covering the roll prompt, the pickup prompt and the popup-queue bit.
- **"Ignore enchants on equipped gear" is gone** — shelved, forced off, no checkbox.
  Step D is now a measurement to record, not a switch to decide.

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
6. If a popup still appears, `/plbisdebug` immediately and copy it out. The lines to
   look for in `[Trace]`:
   - `CONFIRM_LOOT_ROLL: auto-confirming roll N` — we answered it; if a popup is
     still up, the hide failed rather than the confirm.
   - `not our roll, leaving the popup` — that was a **manual** roll, which is meant
     to keep its prompt. Not a bug.
   - **no `CONFIRM_LOOT_ROLL` line at all** — the event never reached us, and my
     whole diagnosis is wrong. That is the most valuable failure to report.
7. Multi-drop: a boss dropping several BoP items at once should need **zero** clicks.

### C. The pickup-bind popup (same setting, on by default now)
8. Nothing to tick — **Auto-Confirm Bind Popups** covers this prompt too. If you
   would rather BoP pickups kept asking, that is the box to untick, and it takes the
   roll confirm with it.
9. Loot a BoP item straight off a corpse. The "this item will bind to you" prompt
   should answer itself. Look for `LOOT_BIND_CONFIRM: auto-confirming loot slot N`.
10. If the prompt lingers on screen after the item is looted, the confirm worked but
    the hide did not — say so, it is a one-line fix (the dialog's `data` is not the
    slot on this client).

### D. Enchant strip — shelved; the table is now just a record
The option is gone (no checkbox, forced off — `BIS-CHECK.md` has the why). What is
left is the measurement, worth re-taking after a big gear change:

11. `/plbisdebug`, read `[Enchant strip check]`. Every equipped slot scored three
    ways: `real` (true instance), `link`, `stripped`.
12. `real` vs `link` is the test — same item, two routes. Round 1 said *"link and
    instance agree on every slot"*. If a later report says *"N slot(s) score
    differently"*, that is worth sending: it means `SetHyperlink` reports
    cached/nominal stats for scaled items here, which would matter to anything that
    ever reads gear by link, not just to the shelved strip.
13. `stripped` vs `link` is the size of the enchant skew you are living with. Two
    slots in round 1. If that ever gets large across most of your gear, the strip is
    worth reconsidering — it is one `initDB` line plus a checkbox.

### E. Win ledger (testable without any BiS drop)
14. `/plbisdebug clear`, then loot 2–3 pieces of equippable gear in one dungeon.
15. `/plbisdebug` → `[This run]` should list them under `won <SLOT>` with scores.
    Empty after looting real gear = the `CHAT_MSG_LOOT` patterns do not match on
    this client. Copy the report; that is a self-contained fix.
16. Leave the zone, `/plbisdebug` again — the ledger should be **empty**.

### F. BiS Check (needs a stale BiS entry — use the dry run instead)
The veto needs one specific item to drop, so force the situation instead:

17. `/plbisdebug item ` then shift-click **an item on your BiS list that is worse
    than what you are wearing** (an old entry you have upgraded past is ideal).
18. Expect `on a rolling BiS list: yes`, and
    `BiS Check WOULD VETO this roll: -N%`. If it says it would not fire, the report
    says which of the three preconditions failed (scannable / weights / filtered).
19. Sanity control: dry-run something **not** on your BiS list — it must say
    `BiS Check would not fire (not on a rolling BiS list)`.
20. If a real veto does fire in a dungeon, the popup should be **red**, headed
    "BiS, but lower", with a **down arrow**, and it must **not** auto-roll. If the
    arrow is a blank box, the texture path is wrong — cosmetic, one line.
21. Let one expire without clicking: it should cast **Greed**, not Need.
22. Then leave the zone: the **"BiS list looks out of date"** window should appear
    listing what was vetoed. "Keep them" changes nothing; "Stop rolling these"
    unticks those items (they stay on the list — check in `/plbismgr`).

### G. Preview (no dungeon needed)
23. Rules page → **Show Loot Advisor**. Press it three times: green "Gear Upgrade",
    gold "High Value", red "BiS, but lower". That is the cheapest way to check the
    down arrow renders.

## 3. What to send back

`/plbisdebug` after any failure, copied whole. The report already carries the
settings, the advisor wiring, the BiS lists, the run ledger and the trace, so a
single paste is usually the entire diagnosis — no need to describe it in prose too.

## 4. Known unverified

What round 1 did not reach, highest-risk first:

- **Both confirm paths.** Neither `CONFIRM_LOOT_ROLL: auto-confirming roll N` nor
  `LOOT_BIND_CONFIRM: auto-confirming loot slot N` has been seen in a trace yet, so
  the root cause in `BIND-CONFIRMS.md` is still a diagnosis. Steps B and C.
- **The merged setting itself**, including the migration of an existing profile
  (step A3) — reasoned and syntax-checked only.
- **`LOOT_BIND` / `CONFIRM_LOOT_ROLL` popup hiding** — the confirm is event-driven
  and solid; the *hide* assumes the client stores the slot/rollID as the dialog's
  `data`.
- **`LOOT_ITEM_*` chat patterns** feeding the ledger, if Ascension reworded loot
  messages.
- **`ZONE_CHANGED_NEW_AREA` timing** on the way out of an instance.
- **`Interface\Buttons\Arrow-Down-Up`** existing in this build.
- **One number worth a second look.** In the round-1 dry run of a *feet* item, the
  report read `score 58.3 vs target 21.9`, while `[Enchant strip check]` scored the
  equipped feet at 58.3 in the same report — those should be the same number, since
  the target for a single-slot group is the equipped item. The gloves dry run agreed
  exactly (43.7 vs target 45.8 = the equipped gloves), so it is not the code path
  being wrong for everything; a cold or half-filled tooltip scan on that one slot is
  the likeliest explanation. Re-run `/plbisdebug item` on a feet item and compare the
  target against the equipped feet row. If it is still low, that is a real bug in
  `ns.effectiveTarget` and it makes BiS Check **under**-fire (everything looks like
  an upgrade), so it is worth catching.
