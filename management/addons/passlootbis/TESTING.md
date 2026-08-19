# In-game test plan — BoP confirms, BiS Check, enchant strip

Everything on this branch is **reasoned and offline-tested only**. Nothing in this
repo can run the 3.3.5 client, so this is the list that turns "should work" into
"does work". Written to be picked up cold in a fresh session — if you are that
session, read `BIND-CONFIRMS.md` and `BIS-CHECK.md` first for why any of it is
shaped the way it is.

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
| `/plbisscan options` (or `/plbs options`) | Scanner settings window — the "Ignore enchants" box lives here |
| `/plbisscan spec` | Check / set the spec whose stat weights are used |
| `/plbismgr` | BiS Manager |

Nothing above writes to SavedVariables. A `/reload` wipes the trace.

## 2. Checks, in the order worth doing them

### A. It loads at all
1. `/reload`, watch for Lua errors. Then `/plbisdebug`.
2. In the report: `[Advisor]` shows the gate enabled and `PLScanner` registered;
   `[Scanner]` shows your class/spec and `weights: yes`; `[Contract self-test]` is
   all `PASS`.
3. Interface → AddOns → PassLoot (BiS) → Options: the two new toggles are there —
   **Auto-Confirm Bind on Roll** (should be ON) and **Auto-Confirm Bind on Pickup**
   (should be OFF).
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

### C. The pickup-bind popup (still off by default)
8. Tick **Auto-Confirm Bind on Pickup** in options.
9. Loot a BoP item straight off a corpse. The "this item will bind to you" prompt
   should answer itself. Look for `LOOT_BIND_CONFIRM: auto-confirming loot slot N`.
10. If the prompt lingers on screen after the item is looted, the confirm worked but
    the hide did not — say so, it is a one-line fix (the dialog's `data` is not the
    slot on this client).

### D. Enchant strip — **verify before enabling**
11. `/plbisdebug`, read `[Enchant strip check]`. It scores every equipped slot three
    ways: `real` (true instance), `link`, `stripped`.
12. **The verdict line is the whole test.** `real` vs `link` describe the same item
    by two routes:
    - *"link and instance agree on every slot"* → safe. Tick **Ignore enchants on
      equipped gear** in `/plbisscan options`.
    - *"N slot(s) score differently"* → **leave it off** and send me the table. It
      means `SetHyperlink` reports cached/nominal stats for scaled items on this
      client, which is a worse error than the enchant skew it would fix.
13. If you do enable it, re-run `/plbisdebug` and check the same items still score
    sanely, then confirm a known upgrade still reads as an upgrade.

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

Nothing in this branch has been confirmed in game. Highest-risk first:

- **The enchant strip's `SetHyperlink` path** — deliberately off; step D decides it.
- **`LOOT_BIND` / `CONFIRM_LOOT_ROLL` popup hiding** — the confirm is event-driven
  and solid; the *hide* assumes the client stores the slot/rollID as the dialog's
  `data`.
- **`LOOT_ITEM_*` chat patterns** feeding the ledger, if Ascension reworded loot
  messages.
- **`ZONE_CHANGED_NEW_AREA` timing** on the way out of an instance.
- **`Interface\Buttons\Arrow-Down-Up`** existing in this build.
