# Auctionator vendor-seed tooling

Maintenance scripts for `Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua`, the bundled
table of confirmed vendor prices that seeds fresh installs. Nothing here ships or is loaded by
the client; run it with `lua5.1` from the **repo root**.

## The file you need

```
<WoW>/WTF/Account/<ACCOUNTNAME>/SavedVariables/Auctionator-Finder-Ascension.lua
```

**Account-level, not per-character.** A file with the same name exists under
`WTF/Account/<ACCT>/<Realm>/<Character>/SavedVariables/`, but `AUCTIONATOR_VENDOR_LEARNED` is
declared under `## SavedVariables` (not `...PerCharacter`) in the `.toc`, so it only ever lands
in the account-level copy. The character file holds tooltip/UI prefs and nothing else; both
scripts reject it with a clear error rather than producing an empty seed.

Fully exit the client (or `/reload`) before copying — WoW flushes SavedVariables at
logout/reload, so a file copied mid-session is missing everything learned that session. Ignore
the `.bak` sibling; it is the previous session's copy.

## Workflow

```sh
lua5.1 management/addons/auctionator/tools/diff-vendor-seed.lua <dump.lua>          # inspect
lua5.1 management/addons/auctionator/tools/gen-vendor-seed.lua  <dump.lua> --dry-run
lua5.1 management/addons/auctionator/tools/gen-vendor-seed.lua  <dump.lua>          # write
luac5.1 -p Auctionator-Finder-Ascension/AuctionatorVendorSeed.lua                   # verify
```

Diff first. `gen-vendor-seed` reports `+N new`, which cannot distinguish a price this player
actually confirmed from the shipped table echoed back into their SavedVariables —
`Atr_VendorSeed_Merge` writes every seeded obs price as `{ p, n = 0, seed = 1 }`, so a dump
always contains the seed it was merged from.

`diff-vendor-seed` splits that apart using the provenance flags and reports these buckets. Two
of them are the reason to run it at all:

- **`*.disagree`** — the same key priced differently in dump and seed. One is wrong; reconcile
  before regenerating.
- **`*.new.echo`** — an entry flagged as seeded whose key the current seed does not contain. It
  can only have come from an *older* shipped seed, so union mode would silently promote a price
  we already chose to drop, laundered as new. This is what "an old dump mixed with a new one"
  looks like from here.

It also audits the dump itself: repeat-sale counts (`n=2` and up are independently
re-confirmed) and item-level monotonicity (a higher-ilvl tuple priced below a lower-ilvl one is
a corrupt record). It deliberately does **not** cross-check `obs` against `base` — an unscaled
sale takes the base branch of `Atr_VendorLearn_OnEvent` and never writes `obs`, so the tables
are disjoint by construction and "0 mismatches" would report a pass where no test ran.

## Harvest dumps vs validation dumps

Two kinds of dump are worth collecting, and they answer different questions.

A **harvest dump** comes from the account the seed is grown on. It carries hundreds of new
tuples, but its agreements with the shipped seed are worthless as evidence — they are the
seed's own source read back. The tell is the echo count: the merge never overwrites a real
observation, so on the origin install it wrote no echoes at all. The diff flags this rather
than let `1342 of 1342 agreeing` be misread as confirmation.

A **validation dump** comes from a fresh install of a *different* account. It adds little, but
it is the only thing that tests the premise the whole seed rests on — that a confirmed
`(itemID:ilvl:req)` price is a global server fact, not something account-local. Look at:

- **`independent re-confirmations`** — seeded tuples this player then sold themselves. Any
  conflict here is a direct hit on the premise and blocks the regeneration.
- **`seed-tier accuracy (pt=seed)`** — `Atr_VendorLearn_OnEvent` stamps `pt = "seed"` when the
  seed answered a prediction no local sale could have informed, so `pp` vs `p` on those rows is
  the shipped table's out-of-sample error against ground truth.
- **`estimator fallback (pt=est)`** — the same score for the estimator that runs where the seed
  has no entry. The gap between these two lines is what a bigger seed actually buys.

`pt = "learned"` rows are repeat sales of a price already stored locally and prove nothing;
both tools ignore them.

## analyze-growth.lua — why the estimator is not fixable by bucketing

```sh
lua5.1 management/addons/auctionator/tools/analyze-growth.lua <dump.lua> [more dumps...] [-v]
```

Every log row carries both the cached unscaled sighting (`bil`, `brq`, `bp`) and what actually
sold (`il`, `rq`, `p`), so each row spans two item levels of one item — and unlike `obs`, log
rows carry `qual`/`cls`/`sub`/`slot`. That makes the log the right dataset for asking whether
price growth clusters by item category. It doesn't:

- Grouping by `cls`, `sub` or `slot` explains at most ~16% of the scatter, and reconstructing
  prices from group-median growth (leave-one-out) scores *worse* than the predictor already
  shipping. Only `qual` beat it, 27.2% vs 30.4% median error — a few points, not a fix.
- The reason every variant plateaus around 27–35%: **growth per item level is the wrong model.**
  The ratio `p / bp` spikes hard on exactly 1.00x (124 rows) and exactly 2.00x (52 rows) —
  45% of samples — with stack size 1 throughout, so it is not a quantity artifact. It is a step
  function, and no smooth per-ilvl curve fits a step function.
- The multiplier is not a function of sale item level either: at ilvl 65, 55 rows sit at 1.00x
  and 32 at 2.00x. Same level, different items, different multiplier.

So the multiplier is a per-item property that cannot be derived from class, subclass, quality,
slot or item level — it has to be observed. Which is what `obs`, `base` and `trk` already do,
and why the seed is the architecture rather than a stopgap for a formula not yet found.

Re-run it as dumps accumulate; the conclusion is only as good as 391 samples from two accounts.

## Conflict counters

`obs` records carry `x` (two real sales of the same tuple disagreed) and `sx` (a real sale
contradicted the shipped seed price); `base` records have carried `x` since they were written.
Either one is a direct refutation of the premise the seed rests on, so the diff surfaces them
as `obs.contested` / `base.contested` and the verdict line fails on them.

**Zero is only meaningful in a dump taken after the counters existed.** The obs counters were
added alongside this tooling, so earlier dumps have no `x`/`sx` at all and report zero because
nothing was watching — the write path used to overwrite `rec.p` in place, which means `n`
counted sales rather than agreement and a contradiction left no trace. `base` conflict counts
are trustworthy further back.

## Two things that will bite you

**`meta.built` is load-bearing.** `Atr_VendorSeed_Merge` refreshes a seed-only entry only when
the shipped version differs from the player's stored `db.seedver` (`prev ~= ver`). Ship new
prices under the old date and every existing install keeps the stale ones. `gen-vendor-seed`
refuses to reuse the current stamp unless you pass `--force-date`.

**`--replace` drops field-tested seed values.** It keeps only `base` records with `seed == nil`,
but a seeded base fact that real unscaled sales later re-confirmed keeps `seed = 1` and just
raises `n` (the vote path never clears the flag). Those are the `base.new.tested` bucket in the
diff. The default union mode keeps them, which is one more reason not to reach for `--replace`
without checking that bucket first.

## sell-variant-smoke.lua — the one thing in here that is not vendor-seed tooling

```
lua5.1 management/addons/auctionator/tools/sell-variant-smoke.lua      # 27 assertions
```

An offline test of the same-name variant bucketing in `AtrSearch:AnalyzeResultsPage` — the loop
that decides which of two items sharing one name (the rare and the epic `Bloodforged Imperial
Jewel`) the SELL tab is looking at. It loads the real `AuctionatorScan.lua` under bare `lua5.1`
with a dozen stubs and replays a page of listings in **both orders**.

It exists because BACKLOG item 16's symptom had already escaped a fix once, and because its cause
was listing order — which is precisely what reading the code kept getting wrong. Against the
pre-fix source it fails 7 of its 27 assertions, and only in the rare-listed-first order; that
asymmetry is the intermittency the owner reported.

**Do not grow it into a client emulator.** It stubs what that one loop touches and nothing else.
