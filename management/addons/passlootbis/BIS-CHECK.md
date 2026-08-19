# BiS Check — the downgrade veto, and the run's win ledger

Feature added 2026-08 at the owner's request. It spans **both** PassLoot addons, so
this file is the one place the whole shape is written down; the code comments carry
the local reasoning.

## The problem

Two ways a BiS list makes you roll on something you have already beaten:

1. **A stale entry.** An item was BiS when you imported the list. You have since
   upgraded past it, but never went back and unticked it. It drops, the rule
   matches, PassLoot Needs it.
2. **Within one run.** You win a shoulder upgrade off the first boss. It goes to
   your *bags*. A worse pair drops off the third boss — and because the scanner
   compares against what you are **wearing**, it still scores as an upgrade.

Both end the same way: you Need an item you do not want, in front of a group that
does.

## Shape of the fix

```
START_LOOT_ROLL
  └─ PasslootBiS:ProcessLootRoll                    (Core/PassLoot.lua)
       ├─ IsBiSItem(id, name) ──────────────────────► ctx.isBiS / ctx.bisList
       └─ HandleRoll(..., ctx, BeforeAdvisor)        (Core/RollAdvisor.lua)
            ├─ ConsultAdvisors(ctx)
            │    └─ PLScanner:GetRollVerdict(rollID, ctx)   (Scanner/Core/Scanner.lua)
            │         └─ compareRoll -> target raised by the win ledger
            │              └─ Verdict.build(..., down)      (Scanner/Core/Verdict.lua)
            ├─ verdict.downgrade ──► VETO: hold the window, never auto-roll
            ├─ BeforeAdvisor      ──► rule wins (everything below is skipped)
            └─ trust modes as before
```

### Why the veto sits above `Before Advisor`

Because the rolls it exists to stop come **from** `Before Advisor` rules. BiS
imports ship with that tick already set, so a check that `Before Advisor` could skip
would never fire on the only rules that need it. `ProcessLootRoll` therefore no
longer *skips* the gate for those rules — it passes the tick in and `HandleRoll`
honours it one line below the veto.

### Why the ledger displaces rather than `math.max`

A win takes the **worst** item in its slot group, it does not raise the whole
group's floor. That distinction only shows up on dual slots and it is the whole
reason `WonLedger.applyWins` exists:

| equipped | won | `max` says | displacement says | right? |
|---|---|---|---|---|
| shoulders `{100}` | 130 | 130 | `{130}` → 130 | same |
| rings `{100, 110}` | 130 | 130 | `{130, 110}` → **110** | displacement |

With `max`, a 120 ring after a 130 win would read as a downgrade — but you have two
finger slots, so it is a real upgrade over the 110 you would actually replace.

**Hand slots are the known approximation.** `ns.weaponEquippedValue` resolves the
1H/2H/dual-wield loadout to a single number, so there is no per-slot list to
displace and the code just raises that one bar. It can under-warn on a dual-wield
pair; it never over-warns, which is the right direction for a check whose false
positive costs you an item outright.

## Decisions (owner, 2026-08)

| Question | Decision |
|---|---|
| Timeout with nobody clicking | **Greed.** Falling through to the rule casts the Need we just called a mistake; casting nothing gives the item away free. Greed contests it without claiming it. If Greed is not allowed on that roll we cast **nothing** — never Need, that is the thing being vetoed. |
| When the win ledger clears | **Zone change**, and on the way out it suggests unticking the entries it found stale. |
| Default | **On.** It only ever *stops* a roll and opens a window; it never casts one you did not ask for. Switch it off with the `BiS Check` box on the advisor status panel. |
| Auto-editing the BiS list | **Never.** The cleanup window suggests; nothing changes until Apply. Unticking clears "auto-roll" only — the item stays on the list and the BiS Manager puts it back. |

## Gotchas worth keeping

- **The verdict table is the entire cross-addon contract.** A field added on one
  side and not the other is dropped silently on arrival — no error, the feature just
  stops. `management/addons/passlootbis/tools/contract-check.lua` pipes a verdict
  through both real files end to end; run it after touching either.
- **`upgrade` and `downgrade` are mutually exclusive**, enforced twice (scanner
  `build`, host `NormalizeVerdict`). Letting both through leaves `HandleRoll`
  vetoing a roll it was simultaneously told to make.
- **AceEvent keeps one handler per event per object.** `PLAYER_ENTERING_WORLD` now
  has two consumers, so both go through `PasslootBiS:OnEnteringWorld`. A second
  `RegisterEvent` for it would *replace* the item-cache reset, not add to it.
- **The veto is gated on `RollMethod ~= nil`.** With no rule-computed roll there was
  nothing to stop, and a red "we held this for you" window over a roll nobody was
  making is pure noise — three times over on a boss that drops three of them.
- **Downgrade never fires the scanner's own alert.** `evaluateRoll` still returns
  early unless there is an upgrade or a gold flag, so the host's veto window is the
  only UI for it. Do not "fix" that into a second popup.

## Diagnostics — `/plbisdebug`

BiS Check is close to untestable on purpose: it needs one specific stale item to
drop off one specific boss. So the trace and the report exist to answer "would it
have fired?" without that.

| Command | Does |
|---|---|
| `/plbisdebug` | Open the report in a **copy box** — click the text, Ctrl+A, Ctrl+C |
| `/plbisdebug on` \| `off` | Start / stop collecting the trace |
| `/plbisdebug chat` | Also echo trace lines live (off by default) |
| `/plbisdebug clear` | Empty the trace |
| `/plbisdebug item <link>` | **Dry-run one item** through BiS Check — shift-click it in |

`item` is the one that matters. It runs the link through `ns.effectiveTarget` and
`ns.judge` — the very functions the live roll path calls — and reports the score,
the target, and whether BiS Check *would* veto. If it says veto, a real roll would
too. Those two helpers were extracted from `compareRoll` precisely so the dry run
cannot answer differently from the feature; do not let a diagnostic grow its own
copy of that arithmetic.

The report also covers the parts that are checkable without any drop at all: the
advisor registry and trust mode, the three source toggles, the scanner's spec and
weights, every rule with its `[BeforeAdvisor]` tick, **the win ledger's current
contents**, and an in-game run of the verdict contract between the *installed*
copies of the two addons (the offline check in `tools/` only proves the two files
in the repo agree — the two folders in `Interface\AddOns` are what can actually be
mismatched).

Two constraints worth keeping:

- **Chat on this client cannot be selected or copied**, so a trace you can only read
  is a trace you cannot report. Everything lands in one selectable EditBox.
- **Nothing is persisted.** The ring, the on/off flag and the echo flag live on the
  addon table, never in `db.profile`, so a `/reload` wipes the lot and no diagnostic
  state is left behind in SavedVariables (owner decision — the SavedVariables file is
  not a debug dump unless there is no alternative, and here there is one).

The trace is **buffered silently by default**; `chat` is opt-in. It is meant to be
left on through a boss pull, and a line per rule per roll would bury the fight.

`tools/report-smoke.lua` exercises the whole report offline against a stubbed addon,
including the degenerate no-scanner case — the report reaches through a lot of
objects that can each be absent, and a nil-index there turns "tell me what went
wrong" into a second thing that went wrong.

## Not verified in game

Everything here is reasoned, syntax-checked (`luac5.1`) and covered by the offline
tests (`WONLEDGER_SELFTEST`, `ROLLADVISOR_SELFTEST`, the contract check). Nothing in
this repo can run the client. The parts most worth watching on a first real run:

- the `|TInterface\Buttons\Arrow-Down-Up:14:14|t` down arrow in the popup headline —
  a missing texture on an Ascension build draws nothing rather than erroring, so a
  blank space there means swap the path;
- the `LOOT_ITEM_*` chat patterns that feed the ledger, if Ascension has reworded
  the loot messages;
- `ZONE_CHANGED_NEW_AREA` timing on the way out of an instance.
