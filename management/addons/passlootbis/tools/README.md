# PasslootBiS tooling

Nothing here ships or is loaded by the client. Run it with `lua5.1` from the **repo root**.

## `proficiency-probe-test.lua`

Offline harness for the client probes in `PasslootBiS/Modules/Proficiency.lua` — it fakes
just enough of the 3.3.5 skill and spell API to run `ScanSkillLines`, `ScanKnownSpells` and
`Detect` with no WoW client.

```
lua5.1 management/addons/passlootbis/tools/proficiency-probe-test.lua
```

It covers the parts the module's own self-test can't reach, in particular the collapsed
skill-header trap: a collapsed header hides its children from `GetNumSkillLines`, so a naive
scan of a character with "Weapon Skills" collapsed reads as *no weapon proficiencies at all* —
which is exactly the input that would otherwise generate "pass on every weapon". The harness
asserts both that the children are still found and that the user's expansion state is put back
exactly as it was.

The module's own pure-logic self-test is separate and runs with:

```
lua5.1 -e 'PROFICIENCY_SELFTEST=true' PasslootBiS/Modules/Proficiency.lua
```

Background and the open in-game questions: `../PROFICIENCY-RULES.md`.
